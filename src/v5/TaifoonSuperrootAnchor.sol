// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Copied from taifoon-eco contracts/TaifoonSuperrootAnchor.sol (the reference) with EXACTLY ONE delta, for the deploy pipeline
// (_DEPLOY_PIPE_v1_ module superroot-anchor): the constructor is `constructor(address _owner, address _updater)` and sets
// `owner = _owner`. The reference sets `owner = msg.sender`, which under CREATE2 through the deterministic deployment proxy
// (0x4e59b44847b379578588920cA78FbF26c0B4956C) would make the proxy the owner. The 2026-10-14 pass replaced the reference's revert
// strings with custom errors (the only other delta); the state, the ring and every function keep the reference's behaviour.

/**
 * TaifoonSuperrootAnchor
 *
 * The trusted-root anchor that makes V5 proof verification complete. The V5
 * verifier proves a blob is INTERNALLY consistent (the chain leaf is in the
 * blob's superroot). This contract supplies the missing half: which superroots
 * are GENUINELY Taifoon's. A relayer (the trusted updater) pushes the live
 * superroot from api.taifoon.dev/api/spinner/superroot every ~10 min; protocols
 * call `isKnownSuperroot(root)` alongside the verifier so a forged-but-
 * self-consistent blob is rejected.
 *
 *   verify(blob) == true  AND  anchor.isKnownSuperroot(blob.superroot)  ==>  trust it.
 *
 * Keeps a bounded ring of recent roots so proofs against a slightly-older
 * superroot (within the window) still verify — proofs aren't always against the
 * very latest root.
 */
contract TaifoonSuperrootAnchor {
    address public owner;
    address public updater; // the relayer key allowed to push roots

    bytes32 public latest;          // most recent superroot
    uint64  public latestBatchId;   // its batch id / timestamp
    uint64  public latestAt;        // block time it was pushed

    // Bounded ring of recently-known roots (so older-but-valid proofs pass).
    uint256 public constant RING = 256;
    bytes32[RING] private _ring;
    uint256 private _head;
    mapping(bytes32 => uint64) public seenAt; // root => block time first seen

    event SuperrootPushed(bytes32 indexed root, uint64 batchId, uint64 at);
    event UpdaterSet(address indexed updater);

    error NotOwner();
    error NotUpdater();
    error NotPendingOwner();
    error ZeroOwner();
    error ZeroRoot();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyUpdater() { if (msg.sender != updater && msg.sender != owner) revert NotUpdater(); _; }

    constructor(address _owner, address _updater) {
        owner = _owner;
        updater = _updater == address(0) ? msg.sender : _updater;
    }

    /// Two-step ownership handoff (ADR-0009: the council Safe owns everything).
    /// Two-step on purpose: a wrong or dead target can never brick ownership,
    /// because the transfer only completes when the new owner accepts.
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, owner);
    }

    function setUpdater(address _updater) external onlyOwner {
        updater = _updater;
        emit UpdaterSet(_updater);
    }

    /// Push the current live superroot. Idempotent on the same root.
    function pushSuperroot(bytes32 root, uint64 batchId) external onlyUpdater {
        if (root == bytes32(0)) revert ZeroRoot();
        if (root == latest) { return; } // no-op on repeat
        latest = root;
        latestBatchId = batchId;
        latestAt = uint64(block.timestamp);
        if (seenAt[root] == 0) {
            seenAt[root] = uint64(block.timestamp);
            _ring[_head % RING] = root;
            _head++;
        }
        emit SuperrootPushed(root, batchId, uint64(block.timestamp));
    }

    /// True if `root` is a Taifoon superroot the anchor has seen (within the ring).
    function isKnownSuperroot(bytes32 root) external view returns (bool) {
        return seenAt[root] != 0;
    }

    /// The freshest root + how old it is (seconds). Protocols can require freshness.
    function current() external view returns (bytes32 root, uint64 batchId, uint64 ageSecs) {
        root = latest;
        batchId = latestBatchId;
        ageSecs = latestAt == 0 ? type(uint64).max : uint64(block.timestamp) - latestAt;
    }
}
