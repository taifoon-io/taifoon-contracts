// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TaifoonMerkle — sparse binary keccak Merkle trees, single and batch proofs.
/// @notice Twin of the Rust crate `taifoon-merkle`; both are tested against the same vectors.
///   leaf     any bytes32 (zero = absent)
///   node     keccak256(left ‖ right)
///   EMPTY[0] = 0, EMPTY[l+1] = keccak256(EMPTY[l] ‖ EMPTY[l])
/// A single proof is `depth` siblings, leaf first; bit l of the index picks left/right at level l (identical
/// to TaifoonV5ProofVerifier._verifyMerkle). A multiproof sends each needed sibling once and empty siblings as
/// one bit, which for a depth-32 block tree is typically 10–15 hashes instead of 32 and shares the path
/// between leaves that are close together.
library TaifoonMerkle {
    error MalformedProof();

    /// @notice Root committed to by `leaf` at `index` with full `siblings`.
    function fold(bytes32 leaf, uint256 index, bytes32[] calldata siblings) internal pure returns (bytes32 cur) {
        cur = leaf;
        uint256 n = siblings.length;
        for (uint256 l = 0; l < n;) {
            cur = (index >> l) & 1 == 0 ? _h(cur, siblings[l]) : _h(siblings[l], cur);
            unchecked { ++l; } // n ≤ 256 (a depth)
        }
    }

    function verify(bytes32 root, uint256 depth, bytes32 leaf, uint256 index, bytes32[] calldata siblings)
        internal
        pure
        returns (bool)
    {
        if (siblings.length != depth || (depth < 256 && index >> depth != 0)) return false;
        return fold(leaf, index, siblings) == root;
    }

    /// @notice Root of a multiproof (see the Rust `MultiProof` for the exact rule). Reverts when malformed.
    /// @param indices strictly increasing leaf indices
    /// @param leaves  the leaves at those indices
    /// @param nodes   non-empty siblings, in consumption order
    /// @param emptyFlags bit k (byte k/8, bit k%8) = 1 when the k-th consumed sibling is an empty subtree
    /// @param flagCount  number of consumed siblings
    function multiRoot(
        uint256 depth,
        uint256[] memory indices,
        bytes32[] memory leaves,
        bytes32[] calldata nodes,
        bytes calldata emptyFlags,
        uint256 flagCount
    ) internal pure returns (bytes32) {
        uint256 n = indices.length;
        if (n == 0 || n != leaves.length || depth == 0 || depth > 64) revert MalformedProof();
        if (emptyFlags.length != (flagCount + 7) / 8) revert MalformedProof();
        for (uint256 i = 0; i < n;) {
            unchecked {
                if (i > 0 && indices[i] <= indices[i - 1]) revert MalformedProof();
                if (indices[i] >> depth != 0) revert MalformedProof();
                ++i;
            }
        }
        uint256 k; // flags consumed
        uint256 m; // nodes consumed
        bytes32 empty; // EMPTY[level], advanced each level
        for (uint256 l = 0; l < depth;) {
            uint256 out;
            uint256 i;
            while (i < n) {
                uint256 idx = indices[i];
                bytes32 h = leaves[i];
                // counters below are bounded by n (≤ the leaves given), depth (≤ 64) and the proof's own lengths
                unchecked {
                    if (idx & 1 == 0 && i + 1 < n && indices[i + 1] == idx + 1) {
                        leaves[out] = _h(h, leaves[i + 1]);
                        i += 2;
                    } else {
                        if (k >= flagCount) revert MalformedProof();
                        bytes32 sib;
                        if ((uint8(emptyFlags[k >> 3]) >> (k & 7)) & 1 == 1) {
                            sib = empty;
                        } else {
                            if (m >= nodes.length) revert MalformedProof();
                            sib = nodes[m++];
                        }
                        k++;
                        leaves[out] = idx & 1 == 0 ? _h(h, sib) : _h(sib, h);
                        i += 1;
                    }
                    indices[out] = idx >> 1;
                    out++;
                }
            }
            n = out;
            empty = _h(empty, empty);
            unchecked { ++l; }
        }
        if (k != flagCount || m != nodes.length || n != 1 || indices[0] != 0) revert MalformedProof();
        if (flagCount & 7 != 0 && uint8(emptyFlags[emptyFlags.length - 1]) >> (flagCount & 7) != 0) {
            revert MalformedProof();
        }
        return leaves[0];
    }

    function _h(bytes32 a, bytes32 b) private pure returns (bytes32 r) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            r := keccak256(0x00, 0x40)
        }
    }
}
