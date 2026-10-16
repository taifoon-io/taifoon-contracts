// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TaifoonTransition} from "../../lib/TaifoonTransition.sol";

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// SCOPE: the ABI of the Taifoon coordination layer's on-chain modules — ONLY.
//
// This file is the chain-ABI header of the coord layer, the way Rome's contracts/interface.sol is the header of
// its precompiles: one interface per module, the structs and events a caller needs, nothing else. It version-
// tracks the modules (anchor · lambda · verifier · payment channel · workflow · donut): its only reason to change is a module
// change. Addresses do NOT live here — they are the same on every EVM chain (CREATE2) and live in Deployments.sol.
//
// Admission rule: an interface belongs here IFF it is a module of the deploy pipeline. Vendors and examples (a
// release on chain B, a listing update) are callers of this ABI and live in their own files.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

/// @title ITaifoonSuperrootAnchor — which superroots are genuinely Taifoon's, on this chain
interface ITaifoonSuperrootAnchor {
    event SuperrootPushed(bytes32 indexed root, uint64 batchId, uint64 at);
    event UpdaterSet(address indexed updater);

    /// @notice Push the live superroot (updater or owner). Idempotent on the same root.
    function pushSuperroot(bytes32 root, uint64 batchId) external;
    /// @notice True when `root` was pushed here (within the ring of 256).
    function isKnownSuperroot(bytes32 root) external view returns (bool);
    /// @notice The freshest root, its batch id and its age in seconds (max uint64 before the first push).
    function current() external view returns (bytes32 root, uint64 batchId, uint64 ageSecs);
    function latest() external view returns (bytes32);
    function seenAt(bytes32 root) external view returns (uint64);
    function owner() external view returns (address);
    function updater() external view returns (address);
    function setUpdater(address updater_) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/// @title ITransitionLambda — the rule that says which move of a protocol's state machine is allowed
interface ITransitionLambda {
    /// @notice Whether `fromState → toState` is a move of `protocolId` for a transition of `kind`.
    function isValidMove(bytes32 protocolId, bytes32 fromState, bytes32 toState, uint8 kind) external view returns (bool);
}

/// @title ITaifoonCoordLambda — the lambda of `taifoon_coord` (twelve hops × five outcomes)
interface ITaifoonCoordLambda is ITransitionLambda {
    /// @notice keccak("<hop>:<outcome>"), the state word as the producer hashes it.
    function stateOf(string calldata hop, string calldata outcome) external pure returns (bytes32);
    /// @notice 0x80 | hop << 3 | outcome, or 0 when the word is not in the vocabulary.
    function codeOf(bytes32 state) external view returns (uint8);
}

/// @title ITaifoonProtocolVerifier — a protocol's transitions, proven under the superroot, on any chain
interface ITaifoonProtocolVerifier {
    /// The protocol's leaf in the superroot at one batch, and its path up.
    struct ProtocolLeaf {
        uint64 historyCount;
        bytes32 stateRoot;
        bytes32 historyRoot;
        uint64 stateCount;
        uint32 leafIndex;
        bytes32[] l3Siblings;
        bytes32 superroot;
    }

    /// A TaifoonMerkle multiproof of transition leaves in the history tree (indices = seqs).
    struct HistoryProof {
        bytes32[] nodes;
        bytes emptyFlags;
        uint256 flagCount;
    }

    /// The order's leaf in the state tree: its current state and the seq of its last transition.
    struct StateProof {
        bytes32 toState;
        uint64 lastSeq;
        bytes32[] siblings;
    }

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

    /// @notice Prove transitions of one protocol under the superroot; every proven leaf is remembered.
    function verifyTransitions(
        bytes32 protocolId,
        ProtocolLeaf calldata pl,
        TaifoonTransition.Transition[] calldata ts,
        HistoryProof calldata hp
    ) external returns (bytes32[] memory leaves);
    /// @notice Prove an order's CURRENT state (the state tree's leaf for the order key).
    function verifyOrderState(bytes32 protocolId, ProtocolLeaf calldata pl, bytes32 orderKeyHash, StateProof calldata sp)
        external
        returns (bool);
    /// @notice Re-check an attested, already proven transition from its signature and payload.
    function checkAttestation(TaifoonTransition.Transition calldata t, bytes calldata payload, bytes calldata signature, uint64 issuedAt)
        external
        view
        returns (bool);
    /// @notice Prove one transition and call an allowed vendor once; `currentLeaf()` names it during the call.
    function executeVerifiedTransition(
        bytes32 protocolId,
        ProtocolLeaf calldata pl,
        TaifoonTransition.Transition calldata t,
        HistoryProof calldata hp,
        address vendor,
        bytes calldata callData
    ) external returns (bytes32 leaf, bool success);
    /// @notice The transition a vendor is being called for (zero outside a call).
    function currentLeaf() external view returns (bytes32);
    /// @notice The superroot a leaf was proven under (zero = not proven here).
    function provenUnder(bytes32 leaf) external view returns (bytes32);
    function executed(bytes32 leaf) external view returns (bool);
    function leafIdOf(bytes32 protocolId) external pure returns (uint64);
    function transitionLeaf(TaifoonTransition.Transition calldata t) external pure returns (bytes32);
    function anchor() external view returns (address);
    function lambdas(bytes32 protocolId) external view returns (address);
    function attesters(bytes32 protocolId, address attester) external view returns (bool);
    function operators(address operator) external view returns (bool);
    function vendors(address vendor) external view returns (bool);
    function setAnchor(address anchor_) external;
    function setLambda(bytes32 protocolId, address lambda) external;
    function setAttester(bytes32 protocolId, address attester, bool allowed) external;
    function setOperator(address operator, bool allowed) external;
    function setVendor(address vendor, bool allowed) external;
}

/// @title ITaifoonPaymentChannel — payer→payee ERC-20 escrow channels settled by vouchers or by a proven sale
interface ITaifoonPaymentChannel {
    enum Status {
        NONE,
        OPEN,
        CLOSING,
        SEALED
    }

    struct Channel {
        address payer;
        Status status;
        uint32 gracePeriod;
        uint64 closureStartedAt;
        address payee;
        bool payerWithdrawn;
        address authorizedSigner;
        address token;
        uint256 salt;
        uint256 deposit;
        uint256 settled;
        uint256 payoutWatermark;
        uint256 paid;
        bytes32 distributionHash;
        bytes32 orderKeyHash;
    }

    /// EIP-712 `Voucher(bytes32 channelId,uint256 cumulative,uint64 expiresAt)`.
    struct Voucher {
        bytes32 channelId;
        uint256 cumulative;
        uint64 expiresAt;
    }

    /// mode 0: amounts are bps (Σ ≤ 10000, the payee takes the remainder); mode 1: token units (Σ == settled).
    struct Distribution {
        uint8 mode;
        address[] recipients;
        uint256[] amounts;
    }

    event Opened(
        bytes32 indexed channelId,
        address indexed payer,
        address indexed payee,
        address token,
        address authorizedSigner,
        uint256 salt,
        uint256 deposit,
        uint32 gracePeriod,
        bytes32 distributionHash,
        bytes32 orderKeyHash
    );
    event Settled(bytes32 indexed channelId, uint256 cumulative, address signer);
    event ToppedUp(bytes32 indexed channelId, uint256 amount, uint256 deposit);
    event CloseRequested(bytes32 indexed channelId, uint64 deadline);
    event Sealed(bytes32 indexed channelId, uint256 settled);
    event PayerWithdrawn(bytes32 indexed channelId, address indexed payer, uint256 amount);
    event Distributed(bytes32 indexed channelId, address indexed recipient, uint256 amount, uint8 mode);
    event PayoutRedirected(bytes32 indexed channelId, address indexed recipient, uint256 amount);
    event DustSwept(bytes32 indexed channelId, uint256 amount);
    event Proven(bytes32 indexed channelId, bytes32 indexed leaf, bytes32 toState);
    event Closed(bytes32 indexed channelId);

    /// @notice Open a channel as the payer: deposit `deposit` of `token`, commit the plan by hash.
    function open(
        address payee,
        address token,
        address authorizedSigner,
        uint256 salt,
        uint256 deposit,
        uint32 gracePeriod,
        bytes32 orderKeyHash,
        Distribution calldata d
    ) external returns (bytes32 channelId);
    /// @notice Permissionless: advance `settled` with a voucher of the authorized signer (OPEN only).
    function settle(Voucher calldata v, bytes calldata signature) external;
    /// @notice Payer: add to the escrow and raise the ceiling (OPEN only).
    function topUp(bytes32 channelId, uint256 amount) external;
    /// @notice Payer: start the grace period (OPEN → CLOSING).
    function requestClose(bytes32 channelId) external;
    /// @notice Permissionless: seal a CLOSING channel after the grace period.
    function seal(bytes32 channelId) external;
    /// @notice Payee: cooperative close, optionally applying one final voucher (empty signature = none).
    function settleAndSeal(bytes32 channelId, Voucher calldata v, bytes calldata signature) external;
    /// @notice Payer, once, in SEALED: take back `deposit − settled`.
    function withdrawPayer(bytes32 channelId) external;
    /// @notice Permissionless: pay the revealed plan (partial in OPEN, final in SEALED: refund, dust, storage deleted).
    function distribute(bytes32 channelId, Distribution calldata d) external;
    /// @notice Verifier only, mid-execution: record the proven state of this channel's sale.
    function onProven(bytes32 channelId, TaifoonTransition.Transition calldata t) external;
    /// @notice Permissionless: a sale proven `settled:ok` releases the whole deposit and seals.
    function sealProven(bytes32 channelId) external;
    function channelOf(bytes32 channelId) external view returns (Channel memory);
    function channelIdOf(address payer, address payee, address token, address authorizedSigner, uint256 salt, uint256 blockNumber)
        external
        pure
        returns (bytes32);
    function distributionHashOf(Distribution calldata d) external pure returns (bytes32);
    function voucherDigest(Voucher calldata v) external view returns (bytes32);
    function provenState(bytes32 channelId) external view returns (bytes32);
    function escrowed(address token) external view returns (uint256);
    function treasury() external view returns (address);
    function verifier() external view returns (address);
    function SETTLED_OK() external view returns (bytes32);
}

/// @title ITsulDonut — the TSUL clause-4 split (70 contributor / 20 reviewers / 10 treasury) of a fee, in native value
interface ITsulDonut {
    event Settled(
        address indexed settler,
        bytes32 indexed bountyId,
        address indexed contributor,
        uint256 callRevenue,
        uint256 fee,
        uint256 toContributor,
        uint256 toReviewers,
        uint256 toTreasury
    );
    event Claimed(address indexed who, uint256 amount);

    /// @notice Authorized settlers only: split `msg.value` (the fee actually charged) 70/20/10, pull-claimable.
    function settle(bytes32 bountyId, address contributor, uint256 callRevenue) external payable;
    /// @notice Take what accrued to the caller.
    function claim() external;
    function claimable(address who) external view returns (uint256);
    function authorizedSettlers(address settler) external view returns (bool);
    function treasury() external view returns (address);
    function reviewerPool() external view returns (address);
    function totalSettled() external view returns (uint256);
    function totalDonut() external view returns (uint256);
    function setSettler(address settler, bool authorized) external;
}

/// @title ITaifoonWorkflow — the workflow builder on chain: an order of states committed once, advanced by proofs
interface ITaifoonWorkflow {
    /// kind 0 NONE (prove only) · 1 CHANNEL (the channel's onProven, args = abi.encode(channelId)) · 2 VENDOR (target's calldata = args)
    struct Binding {
        uint8 kind;
        address target;
    }

    event Registered(bytes32 indexed wfId, bytes32 indexed specHash, uint256 steps);
    event Advanced(bytes32 indexed wfId, bytes32 indexed orderKeyHash, uint32 step, bytes32 leaf, bytes32 toState, uint8 kind);
    event Completed(bytes32 indexed wfId, bytes32 indexed orderKeyHash);

    /// @notice Commit a workflow (once per spec hash): the state of every step in order and its binding.
    function register(bytes32 specHash, bytes32[] calldata states, Binding[] calldata bindings) external returns (bytes32 wfId);
    /// @notice Advance an order one step with the proof of its transition; the step's binding fires in the same call.
    function advance(
        bytes32 wfId,
        bytes32 protocolId,
        ITaifoonProtocolVerifier.ProtocolLeaf calldata pl,
        TaifoonTransition.Transition calldata t,
        ITaifoonProtocolVerifier.HistoryProof calldata hp,
        bytes calldata args
    ) external returns (uint32 step, bytes32 leaf);
    function specHashOf(bytes calldata canonical) external pure returns (bytes32);
    function wfIdOf(bytes32 specHash) external pure returns (bytes32);
    function specOf(bytes32 wfId) external view returns (bytes32 specHash, bytes32[] memory states, Binding[] memory bindings);
    function instanceOf(bytes32 wfId, bytes32 orderKeyHash) external view returns (uint32 next, uint256 total, bool done);
    function nextOf(bytes32 wfId, bytes32 orderKeyHash) external view returns (uint32);
    function used(bytes32 leaf) external view returns (bool);
    function verifier() external view returns (address);
    function channel() external view returns (address);
    function owner() external view returns (address);
    function MAX_STEPS() external view returns (uint256);
}

/// @title ICoordQuote — one quote method across the coord layer's capabilities (Rome's ICostView shape)
/// @dev The selector is the capability's own function selector in this header; `args` is the abi-encoded tuple the
///      write method takes (the donut's adds the fee it will carry as value). Pure/view: safe before signing.
interface ICoordQuote {
    /// @notice The gas the capability is expected to cost and the native value it must carry.
    function quote(bytes4 selector, bytes calldata args) external view returns (uint256 gas, uint256 value);
}
