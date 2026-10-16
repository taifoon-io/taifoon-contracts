// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IJudgeAdapterV5 — Jev's evaluator seat on an assurance hook
/// @notice The surface of the deployed JudgeAdapterV5 (immutable). A verdict is posted by an
///         evaluator only after the same digest is anchored in the Jev decision log by an anchor recorder; a CONFORMANT
///         verdict is queued and released after `releaseDelay`. Live where `TaifoonAddresses.judgeAdapterV5(chainId)` answers.
interface IJudgeAdapterV5 {
    event VerdictPosted(bytes32 indexed jobId, uint8 verdict, uint8 mode, bytes32 digest, address indexed by);
    event VerdictAnchored(bytes32 indexed jobId, bytes32 indexed subject, uint256 index, address indexed recorder);
    event ReleaseQueued(bytes32 indexed jobId, uint64 releasableAt);
    event Released(bytes32 indexed jobId, address by);
    event Vetoed(bytes32 indexed jobId, address by);

    /// @notice verdict: 1 conformant, 2 non-conformant, 3 malformed; mode: 1 deterministic, 2 calibrated.
    function verdictOf(bytes32 jobId) external view returns (uint8 verdict, uint8 mode, bytes32 digest, bool set);
    function subjectOf(bytes32 jobId) external view returns (bytes32);
    function hook() external view returns (address);
    function decisionLog() external view returns (address);
    function treasury() external view returns (address);
    function releaseDelay() external view returns (uint64);
    function isEvaluator(address who) external view returns (bool);
    function isAnchorRecorder(address who) external view returns (bool);
    /// @notice Anyone may release a queued CONFORMANT verdict once its delay has passed.
    function release(bytes32 jobId) external;
}
