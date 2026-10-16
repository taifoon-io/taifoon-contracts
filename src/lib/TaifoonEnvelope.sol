// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TaifoonEnvelope — the coord pipe's envelope hashes, on chain
/// @notice coord-core (taifoon-io/coord `coord-core/src/envelope.rs`) hashes the canonical JSON of a record with keccak256:
///         a genome's `digest` = keccak256(genome.canonical); an envelope's `payload_digest` = keccak256(payload). The
///         canonical JSON is built off chain (sorted keys, no whitespace; the SDK's `t.coord.envelope` builds it); on chain a
///         contract only needs to bind a canonical blob to the digest it was given. Test vectors: test/vectors/envelopes.json
///         (the same file coord-core and the TS SDK pass, byte for byte).
library TaifoonEnvelope {
    error DigestMismatch(bytes32 computed, bytes32 expected);

    /// @notice The digest coord-core gives a canonical blob (a genome's canonical JSON or an envelope's payload).
    function digestOf(bytes memory canonical) internal pure returns (bytes32) {
        return keccak256(canonical);
    }

    /// @notice Revert unless `canonical` hashes to `expected`.
    function requireDigest(bytes memory canonical, bytes32 expected) internal pure {
        bytes32 h = keccak256(canonical);
        if (h != expected) revert DigestMismatch(h, expected);
    }

    /// @notice The order-key hash the pipe and the verifier use for an order key such as `hook:8453:0x…`.
    function orderKeyHash(string memory orderKey) internal pure returns (bytes32) {
        return keccak256(bytes(orderKey));
    }
}
