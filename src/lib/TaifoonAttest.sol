// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TaifoonAttest — the EIP-712 attestation behind an attested transition (twin of taifoon-merkle
///        `transition::attest`, same vectors).
/// @notice An attested transition's leaf commits to (attester, sigHash = keccak(signature), payloadDigest). Given the
///         signature and payload, a contract re-checks it: the signature recovers the attester over the EIP-712
///         digest of the transition, and the hashes match the leaf's.
library TaifoonAttest {
    // literals (inline assembly reads only literal constants); test/sdk/Constants.t.sol pins each to its keccak256
    /// keccak256("EIP712Domain(string name,string version)")
    bytes32 internal constant DOMAIN_TYPEHASH = 0xb03948446334eb9b2196d5eb166f69b9d49403eb4a12f36de8d3f9f3cb8e15c3;
    /// keccak256("Attestation(bytes32 protocolId,bytes32 orderKeyHash,bytes32 fromState,bytes32 toState,bytes32 payloadDigest,uint64 issuedAt)")
    bytes32 internal constant ATTESTATION_TYPEHASH = 0xc8a6f01bdbaa9fd5b1f94e6fc6299a0ad41caa440e2fb037750c0e880e017fcc;

    /// keccak256("Taifoon")
    bytes32 internal constant NAME_HASH = 0xff9195180ab53aef8bc676d975a5fc38d095f8893d35523e67b14f8b83176541;
    /// keccak256("1")
    bytes32 internal constant VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    /// keccak256(abi.encode(DOMAIN_TYPEHASH, keccak("Taifoon"), keccak("1"))): three words over scratch memory; no chainId,
    /// no verifying contract — an attestation is the same on every chain.
    function domainSeparator() internal pure returns (bytes32 h) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, DOMAIN_TYPEHASH)
            mstore(add(p, 32), NAME_HASH)
            mstore(add(p, 64), VERSION_HASH)
            h := keccak256(p, 96)
        }
    }

    /// The EIP-712 digest: `0x1901 ‖ domain ‖ keccak(typehash ‖ the six fields)`, both hashes over scratch memory.
    function digest(bytes32 protocolId, bytes32 orderKeyHash, bytes32 fromState, bytes32 toState, bytes32 payloadDigest, uint64 issuedAt)
        internal pure returns (bytes32 h)
    {
        bytes32 domain = domainSeparator();
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, ATTESTATION_TYPEHASH)
            mstore(add(p, 32), protocolId)
            mstore(add(p, 64), orderKeyHash)
            mstore(add(p, 96), fromState)
            mstore(add(p, 128), toState)
            mstore(add(p, 160), payloadDigest)
            mstore(add(p, 192), and(issuedAt, 0xffffffffffffffff))
            let s := keccak256(p, 224)
            mstore(p, shl(240, 0x1901))
            mstore(add(p, 2), domain)
            mstore(add(p, 34), s)
            h := keccak256(p, 66)
        }
    }

    /// The signer of `d`, or address(0) for a malformed or high-s signature.
    function signer(bytes32 d, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(d, v, r, s);
    }

    /// `signer` over a calldata signature (no copy).
    function signerCalldata(bytes32 d, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(d, v, r, s);
    }

    /// `check` over calldata payload and signature (the verifier's path: nothing copied).
    function checkCalldata(
        address attester, bytes32 sigHash, bytes32 payloadDigest,
        bytes32 protocolId, bytes32 orderKeyHash, bytes32 fromState, bytes32 toState, uint64 issuedAt,
        bytes calldata payload, bytes calldata signature
    ) internal pure returns (bool) {
        if (keccak256(payload) != payloadDigest || keccak256(signature) != sigHash || attester == address(0)) return false;
        return signerCalldata(digest(protocolId, orderKeyHash, fromState, toState, payloadDigest, issuedAt), signature) == attester;
    }

    /// The leaf's attested fields are exactly this signature over this payload by this attester.
    function check(
        address attester, bytes32 sigHash, bytes32 payloadDigest,
        bytes32 protocolId, bytes32 orderKeyHash, bytes32 fromState, bytes32 toState, uint64 issuedAt,
        bytes memory payload, bytes memory signature
    ) internal pure returns (bool) {
        if (keccak256(payload) != payloadDigest || keccak256(signature) != sigHash || attester == address(0)) return false;
        return signer(digest(protocolId, orderKeyHash, fromState, toState, payloadDigest, issuedAt), signature) == attester;
    }
}
