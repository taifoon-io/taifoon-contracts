// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAssuranceHook — the read surface of an assured job
/// @notice The job view of the assurance hook (protocols/ours/assurance-v4), the part a third party reads. The V4 hooks are
///         proxies owned by the council Safe: their implementation can be upgraded by the Safe; this read surface is the
///         stable part. `complete` / `reject` are called by the job's evaluator only (for Jev, JudgeAdapterV5).
///         Live where `TaifoonAddresses.assuranceHook(chainId)` answers.
interface IAssuranceHook {
    function jobs(bytes32 jobId)
        external
        view
        returns (
            address buyer,
            address seller,
            address token,
            uint256 price,
            uint256 premium,
            uint256 deposit,
            uint64 deadline,
            uint64 challengeWindow,
            address pool,
            uint8 state
        );
}
