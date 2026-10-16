// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TaifoonTransition} from "../../src/lib/TaifoonTransition.sol";
import {TaifoonAttest} from "../../src/lib/TaifoonAttest.sol";
import {TaifoonSuperrootAnchor} from "../../src/v5/TaifoonSuperrootAnchor.sol";
import {TaifoonProtocolVerifier} from "../../src/v5/TaifoonProtocolVerifier.sol";
import {TaifoonCoordLambda} from "../../src/v5/TaifoonCoordLambda.sol";
import {TaifoonPaymentChannel} from "../../src/coord/TaifoonPaymentChannel.sol";
import {TaifoonWorkflow} from "../../src/coord/TaifoonWorkflow.sol";
import {TaifoonCoord} from "../../src/coord/sdk/TaifoonCoord.sol";
import {Deployments} from "../../src/coord/sdk/Deployments.sol";
import {CrossChainRelease} from "../../src/coord/sdk/examples/CrossChainRelease.sol";
import {ITaifoonProtocolVerifier, ITaifoonPaymentChannel, ITaifoonWorkflow} from "../../src/coord/sdk/interface.sol";
import {MockUSDC} from "./Mocks.sol";

/// TaifoonWorkflow against the real modules: register once, advance by proof, the three bindings, every refusal.
contract TaifoonWorkflowTest is Test {
    using TaifoonCoord for address;

    uint256 internal constant VAULT_PK = 0xA11CE;
    uint256 internal constant BUYER_PK = 0xBEEF;
    bytes32 internal constant COORD = Deployments.COORD;
    bytes32 internal constant SALE = keccak256(bytes("sale:8453:x402-base:olas-gnosis"));
    bytes32 internal constant SPEC = keccak256(bytes('{"id":"wf:test","schema":"taifoon.coord-workflow.v1"}'));

    MockUSDC internal usdc;
    TaifoonSuperrootAnchor internal anchor;
    TaifoonCoordLambda internal lambda;
    TaifoonProtocolVerifier internal verifier;
    TaifoonPaymentChannel internal channel;
    TaifoonWorkflow internal wf;
    CrossChainRelease internal release;
    address internal vault;
    address internal buyer;
    bytes32 internal hiredOk;
    bytes32 internal settledOk;
    bytes32 internal paidOk;
    uint64 internal batch;

    function setUp() public {
        vault = vm.addr(VAULT_PK);
        buyer = vm.addr(BUYER_PK);
        usdc = new MockUSDC();
        anchor = new TaifoonSuperrootAnchor(address(this), address(this));
        lambda = new TaifoonCoordLambda();
        verifier = new TaifoonProtocolVerifier(address(this), address(anchor));
        verifier.setLambda(COORD, address(lambda));
        verifier.setAttester(COORD, vault, true);
        channel = new TaifoonPaymentChannel(address(this), vault, address(verifier));
        verifier.setVendor(address(channel), true);
        wf = new TaifoonWorkflow(address(this), address(verifier), address(channel));
        verifier.setOperator(address(wf), true);
        release = new CrossChainRelease(address(verifier), address(usdc), buyer, address(this));
        verifier.setVendor(address(release), true);
        usdc.mint(address(release), 1_000_000);
        hiredOk = lambda.stateOf("hired", "ok");
        settledOk = lambda.stateOf("settled", "ok");
        paidOk = lambda.stateOf("paid", "ok");
        usdc.mint(buyer, 1_000_000_000);
        vm.prank(buyer);
        usdc.approve(address(channel), type(uint256).max);
    }

    // ── fixtures ─────────────────────────────────────────────────────────────────────────────────────────────

    function _attested(bytes32 orderKeyHash, bytes32 from, bytes32 to) internal view returns (TaifoonTransition.Transition memory t) {
        t.kind = 1;
        t.protocolId = COORD;
        t.orderKeyHash = orderKeyHash;
        t.fromState = from;
        t.toState = to;
        t.attester = vault;
        t.payloadDigest = keccak256(abi.encodePacked("payload:", orderKeyHash, to));
        bytes32 d = TaifoonAttest.digest(COORD, orderKeyHash, from, to, t.payloadDigest, uint64(block.timestamp));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(VAULT_PK, d);
        t.sigHash = keccak256(abi.encodePacked(r, s, vv));
    }

    /// One-leaf history tree, one-leaf superroot, pushed to the anchor.
    function _world(bytes32 leaf)
        internal
        returns (ITaifoonProtocolVerifier.ProtocolLeaf memory pl, ITaifoonProtocolVerifier.HistoryProof memory hp)
    {
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
        pl.superroot = keccak256(
            abi.encodePacked((uint64(1) << 63) | (uint64(bytes8(COORD)) & ~(uint64(1) << 63)), pl.historyCount, pl.stateRoot, pl.historyRoot, pl.stateCount)
        );
        address(anchor).push(pl.superroot, ++batch);
    }

    function _bindings(uint8 k0, uint8 k1, uint8 k2, address t2) internal pure returns (ITaifoonWorkflow.Binding[] memory b) {
        b = new ITaifoonWorkflow.Binding[](3);
        b[0] = ITaifoonWorkflow.Binding(k0, address(0));
        b[1] = ITaifoonWorkflow.Binding(k1, address(0));
        b[2] = ITaifoonWorkflow.Binding(k2, t2);
    }

    function _states() internal view returns (bytes32[] memory s) {
        s = new bytes32[](3);
        s[0] = hiredOk;
        s[1] = settledOk;
        s[2] = paidOk;
    }

    function _register() internal returns (bytes32 wfId) {
        wfId = address(wf).registerWorkflow(SPEC, _states(), _bindings(0, 1, 2, address(release)));
    }

    function _open(bytes32 orderKeyHash, uint256 price) internal returns (bytes32 id) {
        ITaifoonPaymentChannel.Distribution memory d;
        d.mode = 1;
        d.recipients = new address[](2);
        d.amounts = new uint256[](2);
        d.recipients[0] = vault;
        d.amounts[0] = price / 5;
        d.recipients[1] = makeAddr("seller");
        d.amounts[1] = price - price / 5;
        vm.prank(buyer);
        id = address(channel).open(vault, address(usdc), buyer, 1, price, 1 hours, orderKeyHash, d);
    }

    // ── register ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_register_commits_the_order_once() public {
        bytes32 wfId = _register();
        assertEq(wfId, wf.wfIdOf(SPEC));
        (bytes32 specHash, bytes32[] memory states, ITaifoonWorkflow.Binding[] memory bindings) = ITaifoonWorkflow(address(wf)).specOf(wfId);
        assertEq(specHash, SPEC);
        assertEq(states.length, 3);
        assertEq(states[1], settledOk);
        assertEq(bindings[1].kind, 1);
        assertEq(bindings[2].target, address(release));
        (uint32 next, uint256 total, bool done) = wf.instanceOf(wfId, SALE);
        assertEq(next, 0);
        assertEq(total, 3);
        assertFalse(done);
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.Exists.selector, wfId));
        _register();
    }

    function test_register_refuses_a_bad_shape() public {
        bytes32[] memory s = _states();
        ITaifoonWorkflow.Binding[] memory b = _bindings(0, 1, 2, address(release));
        vm.expectRevert(TaifoonWorkflow.EmptySpec.selector);
        address(wf).registerWorkflow(SPEC, new bytes32[](0), new ITaifoonWorkflow.Binding[](0));
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.LengthMismatch.selector, 3, 2));
        address(wf).registerWorkflow(SPEC, s, new ITaifoonWorkflow.Binding[](2));
        b[2] = ITaifoonWorkflow.Binding(2, address(0));
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.BadBinding.selector, 2, 2, address(0)));
        address(wf).registerWorkflow(SPEC, s, b);
        b[2] = ITaifoonWorkflow.Binding(3, address(release));
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.BadBinding.selector, 2, 3, address(release)));
        address(wf).registerWorkflow(SPEC, s, b);
        // a workflow without a channel refuses a channel binding
        TaifoonWorkflow noChannel = new TaifoonWorkflow(address(this), address(verifier), address(0));
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.BadBinding.selector, 1, 1, address(0)));
        address(noChannel).registerWorkflow(SPEC, s, _bindings(0, 1, 0, address(0)));
        assertEq(wf.specHashOf(bytes('{"a":1}')), keccak256(bytes('{"a":1}')));
    }

    // ── advance: the three bindings ──────────────────────────────────────────────────────────────────────────

    function test_advance_walks_the_order_prove_channel_vendor() public {
        bytes32 wfId = _register();
        uint256 price = 10_000_000;
        bytes32 id = _open(SALE, price);

        // step 0: hired:ok, binding NONE — proven, remembered, nothing else
        TaifoonTransition.Transition memory t0 = _attested(SALE, bytes32(0), hiredOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl0, ITaifoonProtocolVerifier.HistoryProof memory hp0) = _world(TaifoonTransition.leaf(t0));
        vm.expectEmit(true, true, false, true, address(wf));
        emit TaifoonWorkflow.Advanced(wfId, SALE, 0, TaifoonTransition.leaf(t0), hiredOk, 0);
        (uint32 step, bytes32 leaf) = address(wf).advance(wfId, COORD, pl0, t0, hp0, "");
        assertEq(step, 0);
        assertEq(verifier.provenUnder(leaf), pl0.superroot, "proven through the verifier");
        assertTrue(wf.used(leaf));
        assertEq(wf.nextOf(wfId, SALE), 1);

        // step 1: settled:ok, binding CHANNEL — the channel learns the proven state and seals
        TaifoonTransition.Transition memory t1 = _attested(SALE, hiredOk, settledOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl1, ITaifoonProtocolVerifier.HistoryProof memory hp1) = _world(TaifoonTransition.leaf(t1));
        vm.expectEmit(true, true, false, true, address(channel));
        emit TaifoonPaymentChannel.Proven(id, TaifoonTransition.leaf(t1), settledOk);
        (step,) = address(wf).advance(wfId, COORD, pl1, t1, hp1, abi.encode(id));
        assertEq(step, 1);
        assertEq(channel.provenState(id), settledOk);
        assertTrue(verifier.executed(TaifoonTransition.leaf(t1)), "acted on through the verifier, once");
        address(channel).sealProven(id);
        assertEq(uint8(channel.channelOf(id).status), uint8(TaifoonPaymentChannel.Status.SEALED));

        // step 2: paid:ok, binding VENDOR — the release vendor wants settled:ok in view, so it refuses this word
        TaifoonTransition.Transition memory t2 = _attested(SALE, settledOk, paidOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl2, ITaifoonProtocolVerifier.HistoryProof memory hp2) = _world(TaifoonTransition.leaf(t2));
        CrossChainRelease.Release memory r = CrossChainRelease.Release(uint64(block.chainid), SALE, vault, 1234, uint64(block.timestamp + 1 hours));
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(BUYER_PK, release.releaseDigest(r));
        bytes memory call = abi.encodeCall(CrossChainRelease.release, (t2, r, abi.encodePacked(rr, ss, vv)));
        // the vendor refuses a non-settled word: the binding reports the failure and the step does not advance
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.BindingFailed.selector, 2, 2, address(release)));
        address(wf).advance(wfId, COORD, pl2, t2, hp2, call);
        (, , bool done) = wf.instanceOf(wfId, SALE);
        assertFalse(done);
    }

    function test_advance_vendor_binding_completes_the_order() public {
        // a two-step order whose last step is a settled:ok released on "chain B" through the vendor binding
        bytes32[] memory s = new bytes32[](2);
        s[0] = hiredOk;
        s[1] = settledOk;
        ITaifoonWorkflow.Binding[] memory b = new ITaifoonWorkflow.Binding[](2);
        b[0] = ITaifoonWorkflow.Binding(0, address(0));
        b[1] = ITaifoonWorkflow.Binding(2, address(release));
        bytes32 wfId = address(wf).registerWorkflow(keccak256("spec:b"), s, b);
        TaifoonTransition.Transition memory t0 = _attested(SALE, bytes32(0), hiredOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl0, ITaifoonProtocolVerifier.HistoryProof memory hp0) = _world(TaifoonTransition.leaf(t0));
        address(wf).advance(wfId, COORD, pl0, t0, hp0, "");
        TaifoonTransition.Transition memory t1 = _attested(SALE, hiredOk, settledOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl1, ITaifoonProtocolVerifier.HistoryProof memory hp1) = _world(TaifoonTransition.leaf(t1));
        CrossChainRelease.Release memory r = CrossChainRelease.Release(uint64(block.chainid), SALE, vault, 1234, uint64(block.timestamp + 1 hours));
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(BUYER_PK, release.releaseDigest(r));
        uint256 before = usdc.balanceOf(vault);
        vm.expectEmit(true, true, false, false, address(wf));
        emit TaifoonWorkflow.Completed(wfId, SALE);
        address(wf).advance(wfId, COORD, pl1, t1, hp1, abi.encodeCall(CrossChainRelease.release, (t1, r, abi.encodePacked(rr, ss, vv))));
        assertEq(usdc.balanceOf(vault) - before, 1234, "released on chain B by the proven step");
        (uint32 next, uint256 total, bool done) = wf.instanceOf(wfId, SALE);
        assertEq(next, 2);
        assertEq(total, 2);
        assertTrue(done);
        // nothing more: Done
        TaifoonTransition.Transition memory t2 = _attested(SALE, settledOk, paidOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl2, ITaifoonProtocolVerifier.HistoryProof memory hp2) = _world(TaifoonTransition.leaf(t2));
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.Done.selector, wfId, SALE));
        address(wf).advance(wfId, COORD, pl2, t2, hp2, "");
    }

    // ── refusals ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_advance_refuses_wrong_state_replay_unknown_and_foreign_protocol() public {
        bytes32 wfId = _register();
        // the wrong word for step 0
        TaifoonTransition.Transition memory tS = _attested(SALE, bytes32(0), settledOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory plS, ITaifoonProtocolVerifier.HistoryProof memory hpS) = _world(TaifoonTransition.leaf(tS));
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.WrongState.selector, 0, hiredOk, settledOk));
        address(wf).advance(wfId, COORD, plS, tS, hpS, "");
        // unknown workflow
        TaifoonTransition.Transition memory t0 = _attested(SALE, bytes32(0), hiredOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl0, ITaifoonProtocolVerifier.HistoryProof memory hp0) = _world(TaifoonTransition.leaf(t0));
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.Unknown.selector, keccak256("nope")));
        address(wf).advance(keccak256("nope"), COORD, pl0, t0, hp0, "");
        // a bad proof never advances (the verifier refuses: no state moved)
        ITaifoonProtocolVerifier.HistoryProof memory bad = ITaifoonProtocolVerifier.HistoryProof(hp0.nodes, hp0.emptyFlags, 31);
        vm.expectRevert();
        address(wf).advance(wfId, COORD, pl0, t0, bad, "");
        assertEq(wf.nextOf(wfId, SALE), 0);
        assertFalse(wf.used(TaifoonTransition.leaf(t0)), "a reverted advance leaves nothing behind");
        // a foreign protocol id: its leaf is not the one in the superroot (the verifier refuses before the fields are read)
        vm.expectRevert(TaifoonProtocolVerifier.ProtocolLeafNotInSuperroot.selector);
        address(wf).advance(wfId, keccak256("other"), pl0, t0, hp0, "");
        // the good one, then its replay (a second order with the same leaf is impossible: the leaf names the order)
        address(wf).advance(wfId, COORD, pl0, t0, hp0, "");
        bytes32[] memory s2 = new bytes32[](1);
        s2[0] = hiredOk;
        ITaifoonWorkflow.Binding[] memory b2 = new ITaifoonWorkflow.Binding[](1);
        bytes32 wf2 = address(wf).registerWorkflow(keccak256("spec:2"), s2, b2);
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.Replayed.selector, TaifoonTransition.leaf(t0)));
        address(wf).advance(wf2, COORD, pl0, t0, hp0, "");
    }

    function test_channel_binding_refuses_another_sales_channel() public {
        bytes32 wfId = _register();
        bytes32 id = _open(keccak256("another sale"), 5_000_000);
        TaifoonTransition.Transition memory t0 = _attested(SALE, bytes32(0), hiredOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl0, ITaifoonProtocolVerifier.HistoryProof memory hp0) = _world(TaifoonTransition.leaf(t0));
        address(wf).advance(wfId, COORD, pl0, t0, hp0, "");
        TaifoonTransition.Transition memory t1 = _attested(SALE, hiredOk, settledOk);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl1, ITaifoonProtocolVerifier.HistoryProof memory hp1) = _world(TaifoonTransition.leaf(t1));
        // the channel's onProven reverts WrongSale inside the verifier's call: the binding fails, the step holds
        vm.expectRevert(abi.encodeWithSelector(TaifoonWorkflow.BindingFailed.selector, 1, 1, address(channel)));
        address(wf).advance(wfId, COORD, pl1, t1, hp1, abi.encode(id));
        assertEq(wf.nextOf(wfId, SALE), 1);
    }

    function test_ownership_two_step() public {
        address next = makeAddr("next");
        vm.prank(next);
        vm.expectRevert(TaifoonWorkflow.NotOwner.selector);
        wf.transferOwnership(next);
        wf.transferOwnership(next);
        assertEq(wf.pendingOwner(), next);
        vm.expectRevert(TaifoonWorkflow.NotPendingOwner.selector);
        wf.acceptOwnership();
        vm.prank(next);
        wf.acceptOwnership();
        assertEq(wf.owner(), next);
        assertEq(wf.pendingOwner(), address(0));
    }
}
