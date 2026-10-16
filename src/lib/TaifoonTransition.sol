// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TaifoonTransition — the canonical transition leaf (twin of taifoon-merkle `transition`).
/// @notice One fixed 406-byte layout for every protocol, solver, agent and assurance event. kind 0 observed (a log
///         on a chain), 1 attested (signed, off-chain), 2 produced (computed from proven inputs). Fields of the
///         other kinds are zero. leaf = keccak256(abi.encodePacked(all fields)).
library TaifoonTransition {
    struct Transition {
        uint8 kind;
        bytes32 protocolId;     // keccak(protocol id)
        bytes32 orderKeyHash;   // keccak(order key)
        uint64 seq;
        bytes32 fromState;      // keccak(state name), 0 = initial
        bytes32 toState;
        uint64 chainId;         // observed
        uint64 blockNumber;
        bytes32 blockHash;
        uint32 txIndex;
        uint32 logIndex;
        bytes32 logHash;
        address attester;       // attested
        bytes32 sigHash;
        bytes32 payloadDigest;
        bytes32 inputsRoot;     // produced
        bytes32 outputDigest;
        bytes32 manifestHash;
    }

    uint8 internal constant VERSION = 1;

    /// The leaf: keccak256 of the 406 packed bytes (version ‖ kind ‖ protocolId ‖ orderKeyHash ‖ seq ‖ from ‖ to ‖ chainId ‖
    /// blockNumber ‖ blockHash ‖ txIndex ‖ logIndex ‖ logHash ‖ attester ‖ sigHash ‖ payloadDigest ‖ inputsRoot ‖ outputDigest ‖
    /// manifestHash), written field by field in offset order into scratch memory beyond the free pointer (each write covers the
    /// garbage of the previous short field), hashed in place. Same bytes as the Rust and JS twins (the spinner vectors).
    function leaf(Transition memory t) internal pure returns (bytes32 h) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, or(shl(248, VERSION), shl(240, mload(t))))          // 0: version, 1: kind
            mstore(add(p, 2), mload(add(t, 0x20)))                         // 2: protocolId
            mstore(add(p, 34), mload(add(t, 0x40)))                        // 34: orderKeyHash
            mstore(add(p, 66), shl(192, mload(add(t, 0x60))))              // 66: seq u64
            mstore(add(p, 74), mload(add(t, 0x80)))                        // 74: fromState
            mstore(add(p, 106), mload(add(t, 0xa0)))                       // 106: toState
            mstore(add(p, 138), shl(192, mload(add(t, 0xc0))))             // 138: chainId u64
            mstore(add(p, 146), shl(192, mload(add(t, 0xe0))))             // 146: blockNumber u64
            mstore(add(p, 154), mload(add(t, 0x100)))                      // 154: blockHash
            mstore(add(p, 186), shl(224, mload(add(t, 0x120))))            // 186: txIndex u32
            mstore(add(p, 190), shl(224, mload(add(t, 0x140))))            // 190: logIndex u32
            mstore(add(p, 194), mload(add(t, 0x160)))                      // 194: logHash
            mstore(add(p, 226), shl(96, mload(add(t, 0x180))))             // 226: attester 20 bytes
            mstore(add(p, 246), mload(add(t, 0x1a0)))                      // 246: sigHash
            mstore(add(p, 278), mload(add(t, 0x1c0)))                      // 278: payloadDigest
            mstore(add(p, 310), mload(add(t, 0x1e0)))                      // 310: inputsRoot
            mstore(add(p, 342), mload(add(t, 0x200)))                      // 342: outputDigest
            mstore(add(p, 374), mload(add(t, 0x220)))                      // 374: manifestHash → 406
            h := keccak256(p, 406)
        }
    }

    /// The same leaf read straight from calldata (no memory copy of the 18 fields).
    function leafCalldata(Transition calldata t) internal pure returns (bytes32 h) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, or(shl(248, VERSION), shl(240, calldataload(t))))
            mstore(add(p, 2), calldataload(add(t, 0x20)))
            mstore(add(p, 34), calldataload(add(t, 0x40)))
            mstore(add(p, 66), shl(192, calldataload(add(t, 0x60))))
            mstore(add(p, 74), calldataload(add(t, 0x80)))
            mstore(add(p, 106), calldataload(add(t, 0xa0)))
            mstore(add(p, 138), shl(192, calldataload(add(t, 0xc0))))
            mstore(add(p, 146), shl(192, calldataload(add(t, 0xe0))))
            mstore(add(p, 154), calldataload(add(t, 0x100)))
            mstore(add(p, 186), shl(224, calldataload(add(t, 0x120))))
            mstore(add(p, 190), shl(224, calldataload(add(t, 0x140))))
            mstore(add(p, 194), calldataload(add(t, 0x160)))
            mstore(add(p, 226), shl(96, calldataload(add(t, 0x180))))
            mstore(add(p, 246), calldataload(add(t, 0x1a0)))
            mstore(add(p, 278), calldataload(add(t, 0x1c0)))
            mstore(add(p, 310), calldataload(add(t, 0x1e0)))
            mstore(add(p, 342), calldataload(add(t, 0x200)))
            mstore(add(p, 374), calldataload(add(t, 0x220)))
            h := keccak256(p, 406)
        }
    }

    /// @notice The log hash an observed transition commits to; recompute it from a log proven by
    ///         TaifoonV5ReceiptInclusion.proveLog to bind the leaf to the receipt proof.
    function logHash(address emitter, bytes32[] memory topics, bytes memory data) internal pure returns (bytes32) {
        return keccak256(abi.encode(emitter, topics, data));
    }

    function stateIndex(bytes32 orderKeyHash) internal pure returns (uint64) {
        return uint64(bytes8(orderKeyHash));
    }

    /// keccak256(orderKeyHash ‖ toState ‖ uint64 lastSeq): 72 bytes over scratch memory.
    function stateLeaf(bytes32 orderKeyHash, bytes32 toState, uint64 lastSeq) internal pure returns (bytes32 h) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, orderKeyHash)
            mstore(add(p, 32), toState)
            mstore(add(p, 64), shl(192, lastSeq))
            h := keccak256(p, 72)
        }
    }
}
