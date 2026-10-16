// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TaifoonMerkle} from "../lib/TaifoonMerkle.sol";
import {TaifoonTransition} from "../lib/TaifoonTransition.sol";
import {TaifoonAttest} from "../lib/TaifoonAttest.sol";

/// @notice The superroot anchor of this chain (TaifoonSuperrootAnchor): which superroots were pushed here.
interface ISuperrootAnchor {
    function isKnownSuperroot(bytes32 root) external view returns (bool);
}

/// @notice A lambda: the rule that says which move of a protocol's state machine is allowed. One per protocol
///         (TaifoonCoordLambda for `taifoon_coord`, the twelve hops of the one sale run). A protocol without a
///         lambda is only proven, never judged.
interface ITransitionLambda {
    function isValidMove(bytes32 protocolId, bytes32 fromState, bytes32 toState, uint8 kind) external view returns (bool);
}

/// @title TaifoonProtocolVerifier — a protocol's transitions, proven under the superroot, on any chain
/// @notice The producer (spinner, da-api `protocol_trees`) keeps one history tree (append-only transitions, depth
///         32, index = seq) and one state tree (depth 64, index = the order key's first 8 bytes, leaf = the order's
///         current state) per protocol, and folds them into the superroot as one chain-shaped leaf
///         `keccak(leafId ‖ historyCount ‖ stateRoot ‖ historyRoot ‖ stateCount)` with
///         `leafId = 2^63 | protocolId[..8]` (never a chain id). `GET /api/v5/protocol/:protocol/proof?seqs=` and
///         `GET /api/v5/protocol/:protocol/order/:key` serve exactly what this contract checks.
///
///         Three kinds of transition share one 406-byte leaf (TaifoonTransition): 0 observed (a log on a chain the
///         superroot carries: the producer checked the receipt against the stored header), 1 attested (an EIP-712
///         signature of a named attester over the move and a payload digest: a coordination-layer step, a quote, a
///         grade), 2 produced (computed from proven inputs). The same contract on every EVM chain (CREATE2, the
///         deploy pipeline) is what lets a transition proven on chain A be acted on by a contract on chain B.
///
///         Trust: when `anchor` is set, a superroot must have been pushed to this chain's anchor; without one the
///         superroot is asserted by the caller (the `anchored` flag of every event says which).
contract TaifoonProtocolVerifier {
    // ── the proof objects (what the producer serves) ───────────────────────────────────────────────────────────

    /// The protocol's leaf in the superroot at one batch, and its path up.
    struct ProtocolLeaf {
        uint64 historyCount; // transitions in the history tree (the next seq)
        bytes32 stateRoot; // root of the state tree (depth 64)
        bytes32 historyRoot; // root of the history tree (depth 32)
        uint64 stateCount; // orders in the state tree
        uint32 leafIndex; // position of the protocol leaf among the superroot's leaves
        bytes32[] l3Siblings; // protocol leaf → superroot
        bytes32 superroot;
    }

    /// A TaifoonMerkle multiproof of transition leaves in the history tree (indices = the transitions' seqs).
    struct HistoryProof {
        bytes32[] nodes;
        bytes emptyFlags;
        uint256 flagCount;
    }

    /// The order's leaf in the state tree: its current state and the seq of its last transition.
    struct StateProof {
        bytes32 toState;
        uint64 lastSeq;
        bytes32[] siblings; // 64
    }

    // ── state ──────────────────────────────────────────────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;
    ISuperrootAnchor public anchor;
    mapping(address => bool) public operators; // may executeVerifiedTransition
    mapping(address => bool) public vendors; // may be called by executeVerifiedTransition
    mapping(bytes32 => ITransitionLambda) public lambdas; // protocolId → its lambda
    mapping(bytes32 => mapping(address => bool)) public attesters; // protocolId → who may sign its attested transitions
    mapping(bytes32 => bytes32) public provenUnder; // transition leaf → the superroot it was proven under
    mapping(bytes32 => bool) public executed; // transition leaf → acted on once
    bytes32 public currentLeaf; // the transition a vendor is being called for (zero outside a call)
    uint256 private _lock;

    uint64 public constant HISTORY_DEPTH = 32;
    uint64 public constant STATE_DEPTH = 64;

    // ── events ─────────────────────────────────────────────────────────────────────────────────────────────────

    event TransitionProven(
        bytes32 indexed protocolId,
        bytes32 indexed orderKeyHash,
        uint64 seq,
        bytes32 fromState,
        bytes32 toState,
        uint8 kind,
        bytes32 leaf,
        bytes32 superroot,
        bool anchored
    );
    event OrderStateProven(bytes32 indexed protocolId, bytes32 indexed orderKeyHash, bytes32 toState, uint64 lastSeq, bytes32 superroot, bool anchored);
    event TransitionExecuted(bytes32 indexed leaf, address indexed vendor, bytes4 selector, bool success);
    event AnchorSet(address indexed anchor);
    event LambdaSet(bytes32 indexed protocolId, address indexed lambda);
    event AttesterSet(bytes32 indexed protocolId, address indexed attester, bool allowed);
    event OperatorSet(address indexed operator, bool allowed);
    event VendorSet(address indexed vendor, bool allowed);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ── errors ─────────────────────────────────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotOperator();
    error NotPendingOwner();
    error Reentered();
    error NoTransitions();
    error TooManyTransitions();
    error SuperrootUnknown(bytes32 superroot);
    error ProtocolLeafNotInSuperroot();
    error WrongProtocol(uint256 i);
    error SeqBeyondHistory(uint64 seq, uint64 historyCount);
    error HistoryProofInvalid();
    error StateProofInvalid();
    error LambdaRefused(uint256 i, bytes32 fromState, bytes32 toState);
    error AttesterUnknown(uint256 i, address attester);
    error NotProven(bytes32 leaf);
    error AlreadyExecuted(bytes32 leaf);
    error VendorNotAllowed(address vendor);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert NotOperator();
        _;
    }

    /// 1 = free, 2 = entered: the slot never returns to zero, so a guarded call costs a warm non-zero write and
    /// its reset, not a zero → non-zero SSTORE (set once in the constructor).
    modifier nonReentrant() {
        if (_lock == 2) revert Reentered();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address _owner, address _anchor) {
        owner = _owner;
        anchor = ISuperrootAnchor(_anchor);
        _lock = 1;
        emit OwnershipTransferred(address(0), _owner);
        emit AnchorSet(_anchor);
    }

    // ── pure helpers (the producer's own formulas) ─────────────────────────────────────────────────────────────

    /// `protocol_trees::leaf_id`: 2^63 | the protocol id's first 8 bytes (big-endian), never a chain id.
    function leafIdOf(bytes32 protocolId) public pure returns (uint64) {
        return (uint64(1) << 63) | (uint64(bytes8(protocolId)) & ~(uint64(1) << 63));
    }

    /// The protocol leaf in the deployed verifier's chain-leaf layout (TaifoonV5ProofVerifier._chainLeafHash with
    /// chainId = leafId, blockNumber = historyCount, blockHash = stateRoot, miniMmrRoot = historyRoot, twigCount = stateCount).
    function protocolLeafHash(bytes32 protocolId, ProtocolLeaf calldata pl) public pure returns (bytes32 h) {
        uint64 leafId = leafIdOf(protocolId);
        uint64 historyCount = pl.historyCount;
        bytes32 stateRoot = pl.stateRoot;
        bytes32 historyRoot = pl.historyRoot;
        uint64 stateCount = pl.stateCount;
        // keccak256(leafId ‖ historyCount ‖ stateRoot ‖ historyRoot ‖ stateCount): 88 packed bytes over scratch memory
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, or(shl(192, leafId), shl(128, historyCount)))
            mstore(add(p, 16), stateRoot)
            mstore(add(p, 48), historyRoot)
            mstore(add(p, 80), shl(192, stateCount))
            h := keccak256(p, 88)
        }
    }

    /// The history root a multiproof folds to for these leaves at these seqs (TaifoonMerkle.multiRoot, depth 32).
    function historyRootOf(uint256[] calldata indices, bytes32[] calldata leaves, HistoryProof calldata hp) external pure returns (bytes32) {
        return TaifoonMerkle.multiRoot(HISTORY_DEPTH, indices, leaves, hp.nodes, hp.emptyFlags, hp.flagCount);
    }

    /// The same fold in the caller's frame (no self-call: no CALL, no calldata copy of the proof). multiRoot folds IN PLACE,
    /// so it works on copies: the caller's `leaves` (returned, evented) and `indices` stay what they were.
    function _historyRoot(uint256[] memory indices, bytes32[] memory leaves, HistoryProof calldata hp) internal pure returns (bytes32) {
        uint256 n = leaves.length;
        uint256[] memory idx = new uint256[](n);
        bytes32[] memory lv = new bytes32[](n);
        assembly ("memory-safe") {
            // Paris has no MCOPY: a word loop
            let end := add(mul(n, 32), 32)
            for { let o := 32 } lt(o, end) { o := add(o, 32) } {
                mstore(add(idx, o), mload(add(indices, o)))
                mstore(add(lv, o), mload(add(leaves, o)))
            }
        }
        return TaifoonMerkle.multiRoot(HISTORY_DEPTH, idx, lv, hp.nodes, hp.emptyFlags, hp.flagCount);
    }

    /// The leaf of a transition (TaifoonTransition.leaf), for callers that hold the fields.
    function transitionLeaf(TaifoonTransition.Transition calldata t) external pure returns (bytes32) {
        return TaifoonTransition.leafCalldata(t);
    }

    // ── the proofs ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Prove transitions of one protocol: each leaf is rebuilt from its fields, the multiproof folds to the
    ///         history root, the protocol leaf folds to the superroot, and the superroot is one the anchor knows
    ///         (when an anchor is set). An attested transition must name a registered attester of the protocol; a
    ///         protocol with a lambda has every move judged by it. Every proven leaf is remembered with its superroot.
    function verifyTransitions(
        bytes32 protocolId,
        ProtocolLeaf calldata pl,
        TaifoonTransition.Transition[] calldata ts,
        HistoryProof calldata hp
    ) external returns (bytes32[] memory leaves) {
        uint256 n = ts.length;
        if (n == 0) revert NoTransitions();
        if (n > 256) revert TooManyTransitions();
        bool anchored = _bindProtocolLeaf(protocolId, pl);
        leaves = new bytes32[](n);
        uint256[] memory indices = new uint256[](n);
        ITransitionLambda lambda = lambdas[protocolId];
        for (uint256 i = 0; i < n;) {
            TaifoonTransition.Transition calldata t = ts[i];
            if (t.protocolId != protocolId) revert WrongProtocol(i);
            if (t.seq >= pl.historyCount) revert SeqBeyondHistory(t.seq, pl.historyCount);
            if (t.kind == 1 && !attesters[protocolId][t.attester]) revert AttesterUnknown(i, t.attester);
            if (address(lambda) != address(0) && !lambda.isValidMove(protocolId, t.fromState, t.toState, t.kind)) {
                revert LambdaRefused(i, t.fromState, t.toState);
            }
            leaves[i] = TaifoonTransition.leafCalldata(t);
            indices[i] = t.seq;
            unchecked { ++i; } // n ≤ 256
        }
        if (_historyRoot(indices, leaves, hp) != pl.historyRoot) revert HistoryProofInvalid();
        for (uint256 i = 0; i < n;) {
            provenUnder[leaves[i]] = pl.superroot;
            emit TransitionProven(protocolId, ts[i].orderKeyHash, ts[i].seq, ts[i].fromState, ts[i].toState, ts[i].kind, leaves[i], pl.superroot, anchored);
            unchecked { ++i; }
        }
    }

    /// @notice Prove an order's CURRENT state (the state tree's leaf for the order key): what the order is now, not
    ///         only that a transition happened. A different state at the same index does not fold.
    function verifyOrderState(bytes32 protocolId, ProtocolLeaf calldata pl, bytes32 orderKeyHash, StateProof calldata sp)
        external
        returns (bool)
    {
        bool anchored = _bindProtocolLeaf(protocolId, pl);
        bytes32 leaf = TaifoonTransition.stateLeaf(orderKeyHash, sp.toState, sp.lastSeq);
        if (!TaifoonMerkle.verify(pl.stateRoot, STATE_DEPTH, leaf, TaifoonTransition.stateIndex(orderKeyHash), sp.siblings)) {
            revert StateProofInvalid();
        }
        emit OrderStateProven(protocolId, orderKeyHash, sp.toState, sp.lastSeq, pl.superroot, anchored);
        return true;
    }

    /// @notice Re-check an attested transition from its signature and payload: the leaf must be proven here, the
    ///         payload and signature must hash to what the leaf commits to, and the signature must recover the
    ///         attester over the EIP-712 Attestation digest (TaifoonAttest).
    function checkAttestation(
        TaifoonTransition.Transition calldata t,
        bytes calldata payload,
        bytes calldata signature,
        uint64 issuedAt
    ) external view returns (bool) {
        bytes32 leaf = TaifoonTransition.leafCalldata(t);
        if (provenUnder[leaf] == bytes32(0)) revert NotProven(leaf);
        if (t.kind != 1) return false;
        return TaifoonAttest.checkCalldata(
            t.attester, t.sigHash, t.payloadDigest, t.protocolId, t.orderKeyHash, t.fromState, t.toState, issuedAt, payload, signature
        );
    }

    /// @notice Act on one proven transition, once: prove it (as verifyTransitions does, for one leaf), then call an
    ///         allowed vendor contract; during the call `currentLeaf()` names the transition, so the vendor binds its
    ///         effect to it (a release, a mint, a listing update on this chain for a hire settled on another).
    function executeVerifiedTransition(
        bytes32 protocolId,
        ProtocolLeaf calldata pl,
        TaifoonTransition.Transition calldata t,
        HistoryProof calldata hp,
        address vendor,
        bytes calldata callData
    ) external onlyOperator nonReentrant returns (bytes32 leaf, bool success) {
        if (!vendors[vendor]) revert VendorNotAllowed(vendor);
        if (t.protocolId != protocolId) revert WrongProtocol(0);
        if (t.seq >= pl.historyCount) revert SeqBeyondHistory(t.seq, pl.historyCount);
        if (t.kind == 1 && !attesters[protocolId][t.attester]) revert AttesterUnknown(0, t.attester);
        ITransitionLambda lambda = lambdas[protocolId];
        if (address(lambda) != address(0) && !lambda.isValidMove(protocolId, t.fromState, t.toState, t.kind)) {
            revert LambdaRefused(0, t.fromState, t.toState);
        }
        bool anchored = _bindProtocolLeaf(protocolId, pl);
        leaf = TaifoonTransition.leafCalldata(t);
        if (executed[leaf]) revert AlreadyExecuted(leaf);
        bytes32[] memory leaves = new bytes32[](1);
        uint256[] memory indices = new uint256[](1);
        leaves[0] = leaf;
        indices[0] = t.seq;
        if (_historyRoot(indices, leaves, hp) != pl.historyRoot) revert HistoryProofInvalid();
        provenUnder[leaf] = pl.superroot;
        emit TransitionProven(protocolId, t.orderKeyHash, t.seq, t.fromState, t.toState, t.kind, leaf, pl.superroot, anchored);
        executed[leaf] = true;
        currentLeaf = leaf;
        (success,) = vendor.call(callData);
        currentLeaf = bytes32(0);
        bytes4 selector;
        if (callData.length >= 4) selector = bytes4(callData[:4]);
        emit TransitionExecuted(leaf, vendor, selector, success);
    }

    // ── internals ──────────────────────────────────────────────────────────────────────────────────────────────

    function _bindProtocolLeaf(bytes32 protocolId, ProtocolLeaf calldata pl) internal view returns (bool anchored) {
        if (address(anchor) != address(0)) {
            if (!anchor.isKnownSuperroot(pl.superroot)) revert SuperrootUnknown(pl.superroot);
            anchored = true;
        }
        if (TaifoonMerkle.fold(protocolLeafHash(protocolId, pl), pl.leafIndex, pl.l3Siblings) != pl.superroot) {
            revert ProtocolLeafNotInSuperroot();
        }
    }

    // ── admin (the owner: the governance Safe through Conclave) ───────────────────────────────────────────────

    function setAnchor(address _anchor) external onlyOwner {
        anchor = ISuperrootAnchor(_anchor);
        emit AnchorSet(_anchor);
    }

    function setLambda(bytes32 protocolId, address lambda) external onlyOwner {
        lambdas[protocolId] = ITransitionLambda(lambda);
        emit LambdaSet(protocolId, lambda);
    }

    function setAttester(bytes32 protocolId, address attester, bool allowed) external onlyOwner {
        attesters[protocolId][attester] = allowed;
        emit AttesterSet(protocolId, attester, allowed);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function setVendor(address vendor, bool allowed) external onlyOwner {
        vendors[vendor] = allowed;
        emit VendorSet(vendor, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
