// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IJevDecisionLog — the append-only log every Jev decision is recorded in
/// @notice The surface of the deployed JevDecisionLog (no owner, no admin, immutable). Anyone may
///         `record`; a reader decides whose records count by `recorder` (Jev's recorder is the address a deployment names).
///         Live where `TaifoonAddresses.jevDecisionLog(chainId)` answers.
interface IJevDecisionLog {
    struct Decision {
        address recorder;      // who vouches that the judge decided this
        bytes32 kind;          // keccak256 of the decision kind, e.g. keccak256("verdict")
        bytes32 digest;        // hash of the canonical decision
        uint16 confidenceBps;  // the judge's confidence in basis points
        uint64 at;             // block timestamp of the record
        string model;          // the judge's model id
        string uri;            // where the long form can be read
    }

    event Decided(
        bytes32 indexed subject, bytes32 indexed kind, address indexed recorder, uint256 index, bytes32 digest,
        uint16 confidenceBps, string model, string uri
    );

    /// @notice The subject of a decision about `ref` held by contract `at` on chain `chainId`.
    function subjectOf(uint256 chainId, address at, bytes32 ref) external pure returns (bytes32);
    function kindOf(string calldata name) external pure returns (bytes32);
    function record(bytes32 subject, bytes32 kind, bytes32 digest, uint16 confidenceBps, string calldata model, string calldata uri)
        external
        returns (uint256 index);
    function count(bytes32 subject) external view returns (uint256);
    function decisionAt(bytes32 subject, uint256 index) external view returns (Decision memory);
    function decisionsOf(bytes32 subject) external view returns (Decision[] memory);
    /// @notice The last decision on a subject; a zero struct when there is none.
    function latest(bytes32 subject) external view returns (Decision memory);
}
