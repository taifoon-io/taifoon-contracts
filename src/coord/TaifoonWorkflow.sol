// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TaifoonTransition} from "../lib/TaifoonTransition.sol";
import {TaifoonProtocolVerifier} from "../v5/TaifoonProtocolVerifier.sol";

/// @notice The channel's proven hook, as the workflow calls it through the verifier (ITaifoonPaymentChannel.onProven).
interface IWorkflowChannel {
    function onProven(bytes32 channelId, TaifoonTransition.Transition calldata t) external;
}

/// @title TaifoonWorkflow — the workflow builder of the coordination layer, on chain
/// @notice A workflow is the order of states a sale must walk, committed once (`register`) as the hash of its canonical
///         spec (`taifoon.coord-workflow.v1`, coord docs/COORD-SDK.md §3) with one binding per step: what the chain does
///         when that step is proven. Every step is advanced by a PROOF (`advance`): the transition is proven under the
///         anchored superroot through TaifoonProtocolVerifier, its `toState` must be the next state of the instance
///         `(workflow, order)`, and the step's binding fires in the same transaction — the channel's `onProven` for a
///         `channel` binding (so a proven `settled:ok` releases the buyer's escrow), any allowed vendor's call for a
///         `vendor` binding (a release on this chain for a sale settled on another), nothing for `none` (the proof is
///         recorded and the order moves on). The lambda stays the rule of which moves are legal at all; the workflow is
///         the order a buyer, a reseller or a venue pair committed to, and the chain keeps it.
///
///         Permissionless: a proof is the authority. The contract is an OPERATOR of the verifier (the Safe names it, so
///         `executeVerifiedTransition` runs with the workflow in the caller's seat) and binds every effect to the proven
///         leaf; a leaf advances a workflow once.
contract TaifoonWorkflow {
    /// A step's binding: what fires when the step is proven.
    ///   kind 0 NONE     verifyTransitions only (the leaf is proven and remembered)
    ///   kind 1 CHANNEL  executeVerifiedTransition with the payment channel as vendor: onProven(channelId, t); `args` = abi.encode(channelId)
    ///   kind 2 VENDOR   executeVerifiedTransition with `target` as vendor and `args` as its calldata
    struct Binding {
        uint8 kind;
        address target;
    }

    struct Spec {
        bytes32 specHash;
        bytes32[] states;
        Binding[] bindings;
    }

    uint8 public constant NONE = 0;
    uint8 public constant CHANNEL = 1;
    uint8 public constant VENDOR = 2;
    uint256 public constant MAX_STEPS = 64;

    /// TaifoonProtocolVerifier (module protocol-verifier): every advance proves through it.
    TaifoonProtocolVerifier public immutable verifier;
    /// TaifoonPaymentChannel (module payment-channel): the vendor of every `channel` binding.
    address public immutable channel;
    address public owner;
    address public pendingOwner;

    mapping(bytes32 => Spec) internal specs; // wfId → the committed order
    mapping(bytes32 => mapping(bytes32 => uint32)) public nextOf; // wfId → orderKeyHash → the next step
    mapping(bytes32 => bool) public used; // transition leaf → advanced a workflow once

    event Registered(bytes32 indexed wfId, bytes32 indexed specHash, uint256 steps);
    event Advanced(bytes32 indexed wfId, bytes32 indexed orderKeyHash, uint32 step, bytes32 leaf, bytes32 toState, uint8 kind);
    event Completed(bytes32 indexed wfId, bytes32 indexed orderKeyHash);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error EmptySpec();
    error TooManySteps(uint256 n);
    error LengthMismatch(uint256 states, uint256 bindings);
    error BadBinding(uint256 step, uint8 kind, address target);
    error Exists(bytes32 wfId);
    error Unknown(bytes32 wfId);
    error Done(bytes32 wfId, bytes32 orderKeyHash);
    error WrongState(uint32 step, bytes32 expected, bytes32 got);
    error Replayed(bytes32 leaf);
    error ProofMismatch(bytes32 leaf, bytes32 proven);
    error BindingFailed(uint32 step, uint8 kind, address target);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner, address _verifier, address _channel) {
        if (_owner == address(0) || _verifier == address(0)) revert ZeroAddress();
        owner = _owner;
        verifier = TaifoonProtocolVerifier(_verifier);
        channel = _channel;
        emit OwnershipTransferred(address(0), _owner);
    }

    // ── pure ───────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The commitment of a canonical spec (sorted keys, no whitespace: the SDK's `canonical()`).
    function specHashOf(bytes calldata canonical) external pure returns (bytes32) {
        return keccak256(canonical);
    }

    /// @notice The workflow id of a spec hash.
    function wfIdOf(bytes32 specHash) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(specHash));
    }

    // ── views ──────────────────────────────────────────────────────────────────────────────────────────────────

    function specOf(bytes32 wfId) external view returns (bytes32 specHash, bytes32[] memory states, Binding[] memory bindings) {
        Spec storage s = specs[wfId];
        return (s.specHash, s.states, s.bindings);
    }

    /// @notice Where an order stands in a workflow: the next step, the number of steps, whether it is done.
    function instanceOf(bytes32 wfId, bytes32 orderKeyHash) external view returns (uint32 next, uint256 total, bool done) {
        next = nextOf[wfId][orderKeyHash];
        total = specs[wfId].states.length;
        done = total != 0 && next == total;
    }

    // ── register ───────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Commit a workflow: its spec hash, the state of every step in order, and the binding of every step.
    ///         Once per spec hash; anyone may register (a spec is public by its hash).
    function register(bytes32 specHash, bytes32[] calldata states, Binding[] calldata bindings) external returns (bytes32 wfId) {
        uint256 n = states.length;
        if (n == 0) revert EmptySpec();
        if (n > MAX_STEPS) revert TooManySteps(n);
        if (n != bindings.length) revert LengthMismatch(n, bindings.length);
        wfId = wfIdOf(specHash);
        Spec storage s = specs[wfId];
        if (s.states.length != 0) revert Exists(wfId);
        s.specHash = specHash;
        for (uint256 i = 0; i < n;) {
            Binding calldata b = bindings[i];
            if (b.kind > VENDOR) revert BadBinding(i, b.kind, b.target);
            if (b.kind == CHANNEL && channel == address(0)) revert BadBinding(i, b.kind, b.target);
            if (b.kind == VENDOR && b.target == address(0)) revert BadBinding(i, b.kind, b.target);
            s.states.push(states[i]);
            s.bindings.push(b);
            unchecked { ++i; } // n ≤ MAX_STEPS
        }
        emit Registered(wfId, specHash, n);
    }

    // ── advance ────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Advance an order one step with a proof of its transition: `t.toState` must be the next state of the
    ///         workflow for `t.orderKeyHash`; the leaf is proven through the verifier (and acted on, per the binding).
    /// @param args the binding's arguments: abi.encode(channelId) for CHANNEL, the vendor calldata for VENDOR, empty for NONE
    function advance(
        bytes32 wfId,
        bytes32 protocolId,
        TaifoonProtocolVerifier.ProtocolLeaf calldata pl,
        TaifoonTransition.Transition calldata t,
        TaifoonProtocolVerifier.HistoryProof calldata hp,
        bytes calldata args
    ) external returns (uint32 step, bytes32 leaf) {
        Spec storage s = specs[wfId];
        uint256 n = s.states.length;
        if (n == 0) revert Unknown(wfId);
        step = nextOf[wfId][t.orderKeyHash];
        if (step >= n) revert Done(wfId, t.orderKeyHash);
        bytes32 expected = s.states[step];
        if (t.toState != expected) revert WrongState(step, expected, t.toState);
        leaf = TaifoonTransition.leafCalldata(t);
        if (used[leaf]) revert Replayed(leaf);
        used[leaf] = true;
        unchecked { nextOf[wfId][t.orderKeyHash] = step + 1; } // step < n ≤ 64
        Binding storage b = s.bindings[step];
        if (b.kind == NONE) {
            TaifoonTransition.Transition[] memory ts = new TaifoonTransition.Transition[](1);
            ts[0] = t;
            bytes32[] memory leaves = verifier.verifyTransitions(protocolId, pl, ts, hp);
            if (leaves[0] != leaf) revert ProofMismatch(leaf, leaves[0]);
        } else {
            address vendor = b.kind == CHANNEL ? channel : b.target;
            bytes memory callData = b.kind == CHANNEL ? abi.encodeCall(IWorkflowChannel.onProven, (abi.decode(args, (bytes32)), t)) : args;
            (bytes32 proven, bool ok) = verifier.executeVerifiedTransition(protocolId, pl, t, hp, vendor, callData);
            if (proven != leaf) revert ProofMismatch(leaf, proven);
            if (!ok) revert BindingFailed(step, b.kind, vendor);
        }
        emit Advanced(wfId, t.orderKeyHash, step, leaf, t.toState, b.kind);
        if (step + 1 == n) emit Completed(wfId, t.orderKeyHash);
    }

    // ── admin (the owner: the governance Safe through Conclave) ───────────────────────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}
