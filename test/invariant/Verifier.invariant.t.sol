// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TaifoonTransition} from "../../src/lib/TaifoonTransition.sol";
import {TaifoonProtocolVerifier} from "../../src/v5/TaifoonProtocolVerifier.sol";

/// A vendor that records how many times it was called for each leaf in view.
contract CountingVendor {
    TaifoonProtocolVerifier public immutable verifier;
    mapping(bytes32 => uint256) public hits;

    constructor(TaifoonProtocolVerifier v) {
        verifier = v;
    }

    function act() external {
        hits[verifier.currentLeaf()]++;
    }
}

/// The handler: random one-leaf worlds proven and acted on, replays attempted, with ghost records of every leaf ever executed.
contract VerifierHandler is Test {
    TaifoonProtocolVerifier public verifier;
    CountingVendor public vendor;
    bytes32 internal constant P = keccak256("inv_protocol");
    bytes32[] public executedLeaves;
    mapping(bytes32 => bytes32) public rootOf; // leaf → the superroot it was proven under, as the handler saw it
    uint256 public replaysRefused;

    constructor(TaifoonProtocolVerifier v, CountingVendor cv) {
        verifier = v;
        vendor = cv;
    }

    function _world(bytes32 leaf) internal pure returns (TaifoonProtocolVerifier.ProtocolLeaf memory pl, TaifoonProtocolVerifier.HistoryProof memory hp) {
        bytes32 cur = leaf;
        bytes32 empty = bytes32(0);
        for (uint256 l = 0; l < 32; l++) {
            cur = keccak256(abi.encodePacked(cur, empty));
            empty = keccak256(abi.encodePacked(empty, empty));
        }
        pl.historyCount = 1;
        pl.historyRoot = cur;
        pl.stateRoot = bytes32(uint256(7));
        pl.stateCount = 1;
        pl.l3Siblings = new bytes32[](0);
        hp.emptyFlags = hex"ffffffff";
        hp.flagCount = 32;
        pl.superroot = keccak256(abi.encodePacked((uint64(1) << 63) | (uint64(bytes8(P)) & ~(uint64(1) << 63)), pl.historyCount, pl.stateRoot, pl.historyRoot, pl.stateCount));
    }

    function execute(uint256 seed) external {
        TaifoonTransition.Transition memory t;
        t.kind = 0;
        t.protocolId = P;
        t.orderKeyHash = keccak256(abi.encode("order", seed % 13));
        t.toState = keccak256(abi.encode("state", seed % 5));
        t.chainId = 8453;
        t.blockNumber = uint64(seed);
        bytes32 leaf = TaifoonTransition.leaf(t);
        (TaifoonProtocolVerifier.ProtocolLeaf memory pl, TaifoonProtocolVerifier.HistoryProof memory hp) = _world(leaf);
        if (verifier.executed(leaf)) {
            vm.expectRevert(abi.encodeWithSelector(TaifoonProtocolVerifier.AlreadyExecuted.selector, leaf));
            verifier.executeVerifiedTransition(P, pl, t, hp, address(vendor), abi.encodeCall(CountingVendor.act, ()));
            replaysRefused++;
            return;
        }
        (bytes32 proven, bool ok) = verifier.executeVerifiedTransition(P, pl, t, hp, address(vendor), abi.encodeCall(CountingVendor.act, ()));
        assertEq(proven, leaf);
        assertTrue(ok);
        executedLeaves.push(leaf);
        rootOf[leaf] = pl.superroot;
    }

    function count() external view returns (uint256) {
        return executedLeaves.length;
    }
}

/// An executed leaf stays executed, keeps the superroot it was proven under, and was acted on exactly once;
/// `currentLeaf` is zero between calls.
contract VerifierInvariant is Test {
    TaifoonProtocolVerifier internal verifier;
    CountingVendor internal vendor;
    VerifierHandler internal h;

    function setUp() public {
        verifier = new TaifoonProtocolVerifier(address(this), address(0));
        vendor = new CountingVendor(verifier);
        h = new VerifierHandler(verifier, vendor);
        verifier.setOperator(address(h), true);
        verifier.setVendor(address(vendor), true);
        targetContract(address(h));
    }

    function invariant_executed_never_flips_and_acts_once() public view {
        uint256 n = h.count();
        for (uint256 i = 0; i < n; i++) {
            bytes32 leaf = h.executedLeaves(i);
            assertTrue(verifier.executed(leaf), "executed stays");
            assertEq(verifier.provenUnder(leaf), h.rootOf(leaf), "proven under the same superroot");
            assertEq(vendor.hits(leaf), 1, "acted on exactly once");
        }
        assertEq(verifier.currentLeaf(), bytes32(0), "no leaf in view between calls");
    }
}
