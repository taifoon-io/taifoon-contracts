// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// The typehash and name literals the assembly digests read are exactly the keccak256 of their strings.
contract ConstantsTest is Test {
    function test_literals_are_their_keccaks() public pure {
        assertEq(bytes32(0xb03948446334eb9b2196d5eb166f69b9d49403eb4a12f36de8d3f9f3cb8e15c3), keccak256("EIP712Domain(string name,string version)"));
        assertEq(bytes32(0xc8a6f01bdbaa9fd5b1f94e6fc6299a0ad41caa440e2fb037750c0e880e017fcc), keccak256("Attestation(bytes32 protocolId,bytes32 orderKeyHash,bytes32 fromState,bytes32 toState,bytes32 payloadDigest,uint64 issuedAt)"));
        assertEq(bytes32(0xff9195180ab53aef8bc676d975a5fc38d095f8893d35523e67b14f8b83176541), keccak256("Taifoon"));
        assertEq(bytes32(0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6), keccak256("1"));
        assertEq(bytes32(0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f), keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"));
        assertEq(bytes32(0xde032b55f23cfa976e0cf58f44a51b0900e10d45617be6db39758f8e8f09d24e), keccak256("Voucher(bytes32 channelId,uint256 cumulative,uint64 expiresAt)"));
        assertEq(bytes32(0xea03d49bcdc594f44f9fc6e398313cef63bfc3e3fcbd53afc04e73afa0e6c997), keccak256("TaifoonPaymentChannel"));
        assertEq(bytes32(0x1e351c13c494486eeed5c0c13a53a5d0b1063f3ffb657a5943da3d4c11d009f3), keccak256("Release(uint64 dstChainId,bytes32 orderKeyHash,address payee,uint256 amount,uint64 deadline)"));
        assertEq(bytes32(0x60359a5387e971583c839868741b4833386c098b639d57bce24099dc8568e75d), keccak256("TaifoonCrossChainRelease"));
    }
}
