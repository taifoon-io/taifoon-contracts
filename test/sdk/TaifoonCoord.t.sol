// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TaifoonTransition} from "../../src/lib/TaifoonTransition.sol";
import {TaifoonAttest} from "../../src/lib/TaifoonAttest.sol";
import {TaifoonSuperrootAnchor} from "../../src/v5/TaifoonSuperrootAnchor.sol";
import {TaifoonProtocolVerifier} from "../../src/v5/TaifoonProtocolVerifier.sol";
import {TaifoonCoordLambda} from "../../src/v5/TaifoonCoordLambda.sol";
import {TaifoonPaymentChannel} from "../../src/coord/TaifoonPaymentChannel.sol";
import {TsulDonut} from "../../src/coord/vendor/TsulDonut.sol";
import {TaifoonCoord} from "../../src/coord/sdk/TaifoonCoord.sol";
import {CoordQuote} from "../../src/coord/sdk/CoordQuote.sol";
import {Deployments} from "../../src/coord/sdk/Deployments.sol";
import {CrossChainRelease} from "../../src/coord/sdk/examples/CrossChainRelease.sol";
import {
    ITaifoonSuperrootAnchor,
    ITaifoonProtocolVerifier,
    ITaifoonPaymentChannel,
    ITsulDonut,
    ICoordQuote
} from "../../src/coord/sdk/interface.sol";
import {MockUSDC, LeafStub} from "./Mocks.sol";

/// The payee of a channel, reaching the layer through the library like any other contract.
contract PayeeAgent {
    function settleAndSeal(address channel, bytes32 id, ITaifoonPaymentChannel.Voucher memory v, bytes memory sig) external {
        TaifoonCoord.settleAndSeal(channel, id, v, sig);
    }
}

/// Every wrapper of TaifoonCoord against the real modules; the quote; the cross-chain release example.
contract TaifoonCoordTest is Test {
    using TaifoonCoord for address;

    uint256 internal constant VAULT_PK = 0xA11CE;
    uint256 internal constant SIGNER_PK = 0xB0B;
    uint256 internal constant BUYER_PK = 0xBEEF;
    bytes32 internal constant COORD = Deployments.COORD;
    bytes32 internal constant SALE = keccak256(bytes("sale:8453:0xabc"));

    MockUSDC internal usdc;
    TaifoonSuperrootAnchor internal anchor;
    TaifoonCoordLambda internal lambda;
    TaifoonProtocolVerifier internal verifier;
    TaifoonPaymentChannel internal channel;
    TsulDonut internal donut;
    PayeeAgent internal payee;
    CoordQuote internal quoteContract;
    address internal vault;
    address internal signer;

    function setUp() public {
        vault = vm.addr(VAULT_PK);
        signer = vm.addr(SIGNER_PK);
        usdc = new MockUSDC();
        anchor = new TaifoonSuperrootAnchor(address(this), address(this));
        lambda = new TaifoonCoordLambda();
        verifier = new TaifoonProtocolVerifier(address(this), address(anchor));
        verifier.setLambda(COORD, address(lambda));
        verifier.setAttester(COORD, vault, true);
        verifier.setOperator(address(this), true);
        channel = new TaifoonPaymentChannel(address(this), vault, address(verifier));
        verifier.setVendor(address(channel), true);
        donut = new TsulDonut(address(this), Deployments.SAFE, vault, address(0));
        donut.setSettler(address(this), true);
        payee = new PayeeAgent();
        quoteContract = new CoordQuote(address(this));
        usdc.mint(address(this), 100_000_000);
        usdc.approve(address(channel), type(uint256).max);
        vm.deal(address(this), 10 ether);
        vm.warp(1_791_900_000);
    }

    // ── fixtures ─────────────────────────────────────────────────────────────────────────────────────────────

    function _transition(bytes32 orderKeyHash, bytes32 toState, bytes memory payload)
        internal
        pure
        returns (TaifoonTransition.Transition memory t, bytes memory sig)
    {
        t.kind = 1;
        t.protocolId = COORD;
        t.orderKeyHash = orderKeyHash;
        t.toState = toState;
        t.attester = vm.addr(VAULT_PK);
        t.payloadDigest = keccak256(payload);
        bytes32 d = TaifoonAttest.digest(COORD, orderKeyHash, bytes32(0), toState, t.payloadDigest, 1_791_900_000);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(VAULT_PK, d);
        sig = abi.encodePacked(r, s, vv);
        t.sigHash = keccak256(sig);
    }

    /// One-leaf history tree + a real one-order state tree (the order's leaf at its 64-bit index), one-leaf superroot.
    function _world(TaifoonTransition.Transition memory t)
        internal
        pure
        returns (
            ITaifoonProtocolVerifier.ProtocolLeaf memory pl,
            ITaifoonProtocolVerifier.HistoryProof memory hp,
            ITaifoonProtocolVerifier.StateProof memory sp
        )
    {
        bytes32 cur = TaifoonTransition.leaf(t);
        bytes32 empty = bytes32(0);
        for (uint256 l = 0; l < 32; l++) {
            cur = keccak256(abi.encodePacked(cur, empty));
            empty = keccak256(abi.encodePacked(empty, empty));
        }
        pl.historyCount = 1;
        pl.historyRoot = cur;
        sp.toState = t.toState;
        sp.lastSeq = 0;
        sp.siblings = new bytes32[](64);
        uint256 idx = TaifoonTransition.stateIndex(t.orderKeyHash);
        cur = TaifoonTransition.stateLeaf(t.orderKeyHash, t.toState, 0);
        empty = bytes32(0);
        for (uint256 l = 0; l < 64; l++) {
            sp.siblings[l] = empty;
            cur = (idx >> l) & 1 == 0 ? keccak256(abi.encodePacked(cur, empty)) : keccak256(abi.encodePacked(empty, cur));
            empty = keccak256(abi.encodePacked(empty, empty));
        }
        pl.stateRoot = cur;
        pl.stateCount = 1;
        pl.l3Siblings = new bytes32[](0);
        hp.emptyFlags = hex"ffffffff";
        hp.flagCount = 32;
        pl.superroot = keccak256(
            abi.encodePacked((uint64(1) << 63) | (uint64(bytes8(COORD)) & ~(uint64(1) << 63)), pl.historyCount, pl.stateRoot, pl.historyRoot, pl.stateCount)
        );
    }

    function _plan() internal view returns (ITaifoonPaymentChannel.Distribution memory d) {
        d.mode = 0;
        d.recipients = new address[](1);
        d.amounts = new uint256[](1);
        d.recipients[0] = vault;
        d.amounts[0] = 2000;
    }

    function _voucher(bytes32 id, uint256 cumulative) internal view returns (ITaifoonPaymentChannel.Voucher memory v, bytes memory sig) {
        v = ITaifoonPaymentChannel.Voucher(id, cumulative, uint64(block.timestamp + 1 days));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, channel.voucherDigest(TaifoonPaymentChannel.Voucher(id, cumulative, v.expiresAt)));
        sig = abi.encodePacked(r, s, vv);
    }

    // ── the header is the modules' ABI ───────────────────────────────────────────────────────────────────────

    function test_interface_selectors_match_the_modules() public pure {
        assertEq(ITaifoonPaymentChannel.open.selector, TaifoonPaymentChannel.open.selector);
        assertEq(ITaifoonPaymentChannel.distribute.selector, TaifoonPaymentChannel.distribute.selector);
        assertEq(ITaifoonPaymentChannel.onProven.selector, TaifoonPaymentChannel.onProven.selector);
        assertEq(ITaifoonPaymentChannel.settleAndSeal.selector, TaifoonPaymentChannel.settleAndSeal.selector);
        assertEq(ITaifoonProtocolVerifier.executeVerifiedTransition.selector, TaifoonProtocolVerifier.executeVerifiedTransition.selector);
        assertEq(ITaifoonProtocolVerifier.verifyTransitions.selector, TaifoonProtocolVerifier.verifyTransitions.selector);
        assertEq(ITaifoonSuperrootAnchor.pushSuperroot.selector, TaifoonSuperrootAnchor.pushSuperroot.selector);
        assertEq(ITsulDonut.settle.selector, TsulDonut.settle.selector);
    }

    // ── anchor ───────────────────────────────────────────────────────────────────────────────────────────────

    function test_anchor_wrappers() public {
        bytes32 root = keccak256("root");
        assertFalse(address(anchor).anchored(root));
        (, , uint64 age) = address(anchor).current();
        assertEq(age, type(uint64).max, "nothing pushed yet");
        address(anchor).push(root, 42);
        assertTrue(address(anchor).anchored(root));
        (bytes32 got, uint64 batch, uint64 age2) = address(anchor).current();
        assertEq(got, root);
        assertEq(batch, 42);
        assertEq(age2, 0);
    }

    // ── verifier ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_verifier_wrappers_prove_proveOrder_act_checkAttestation() public {
        bytes memory payload = bytes('{"step":"settled","outcome":"ok"}');
        (TaifoonTransition.Transition memory t, bytes memory sig) = _transition(SALE, lambda.stateOf("settled", "ok"), payload);
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl, ITaifoonProtocolVerifier.HistoryProof memory hp, ITaifoonProtocolVerifier.StateProof memory sp) = _world(t);
        address(anchor).push(pl.superroot, 1);

        TaifoonTransition.Transition[] memory ts = new TaifoonTransition.Transition[](1);
        ts[0] = t;
        bytes32[] memory leaves = address(verifier).prove(COORD, pl, ts, hp);
        assertEq(leaves[0], TaifoonTransition.leaf(t));
        assertEq(verifier.provenUnder(leaves[0]), pl.superroot);
        assertTrue(address(verifier).proveOrder(COORD, pl, SALE, sp), "the order's current state folds to the state root");
        assertTrue(address(verifier).checkAttestation(t, payload, sig, 1_791_900_000));
        assertFalse(address(verifier).checkAttestation(t, bytes("other"), sig, 1_791_900_000));

        bytes32 id = address(channel).open(address(payee), address(usdc), signer, 1, 1_000_000, 1 hours, SALE, _plan());
        (bytes32 leaf, bool ok) = address(verifier).act(COORD, pl, t, hp, address(channel), abi.encodeCall(ITaifoonPaymentChannel.onProven, (id, t)));
        assertTrue(ok);
        assertEq(leaf, leaves[0]);
        assertEq(channel.provenState(id), lambda.stateOf("settled", "ok"));
    }

    // ── channel ──────────────────────────────────────────────────────────────────────────────────────────────

    function test_channel_wrappers_voucher_path() public {
        ITaifoonPaymentChannel.Distribution memory d = _plan();
        bytes32 id = address(channel).open(address(payee), address(usdc), signer, 7, 1_000_000, 1 hours, SALE, d);
        assertEq(channel.channelOf(id).payer, address(this), "the library's caller is the payer");

        (ITaifoonPaymentChannel.Voucher memory v, bytes memory sig) = _voucher(id, 100_000);
        address(channel).settle(v, sig);
        assertEq(channel.channelOf(id).settled, 100_000);
        address(channel).topUp(id, 500_000);
        assertEq(channel.channelOf(id).deposit, 1_500_000);
        address(channel).distribute(id, d);
        assertEq(usdc.balanceOf(vault), 20_000, "2000 bps of 100_000");
        assertEq(usdc.balanceOf(address(payee)), 80_000, "the payee's remainder");

        address(channel).requestClose(id);
        assertEq(uint8(channel.channelOf(id).status), uint8(TaifoonPaymentChannel.Status.CLOSING));
        (v, sig) = _voucher(id, 400_000);
        payee.settleAndSeal(address(channel), id, v, sig);
        assertEq(uint8(channel.channelOf(id).status), uint8(TaifoonPaymentChannel.Status.SEALED));
        assertEq(channel.channelOf(id).settled, 400_000);

        uint256 before = usdc.balanceOf(address(this));
        address(channel).withdrawPayer(id);
        assertEq(usdc.balanceOf(address(this)) - before, 1_100_000);
        address(channel).distribute(id, d);
        assertEq(usdc.balanceOf(vault), 80_000);
        assertEq(usdc.balanceOf(address(payee)), 320_000);
        assertEq(uint8(channel.channelOf(id).status), uint8(TaifoonPaymentChannel.Status.NONE));
    }

    function test_channel_wrappers_seal_after_grace_and_sealProven() public {
        bytes32 id = address(channel).open(address(payee), address(usdc), signer, 8, 1_000_000, 1 hours, SALE, _plan());
        address(channel).requestClose(id);
        vm.warp(block.timestamp + 1 hours);
        address(channel).seal(id);
        assertEq(uint8(channel.channelOf(id).status), uint8(TaifoonPaymentChannel.Status.SEALED));

        vm.roll(block.number + 1);
        bytes32 id2 = address(channel).open(address(payee), address(usdc), signer, 8, 1_000_000, 1 hours, SALE, _plan());
        (TaifoonTransition.Transition memory t,) = _transition(SALE, lambda.stateOf("settled", "ok"), bytes("x"));
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl, ITaifoonProtocolVerifier.HistoryProof memory hp,) = _world(t);
        address(anchor).push(pl.superroot, 2);
        (, bool ok) = address(verifier).act(COORD, pl, t, hp, address(channel), abi.encodeCall(ITaifoonPaymentChannel.onProven, (id2, t)));
        assertTrue(ok);
        address(channel).sealProven(id2);
        assertEq(channel.channelOf(id2).settled, 1_000_000);
    }

    // ── donut ────────────────────────────────────────────────────────────────────────────────────────────────

    function test_settleDonut_splits_70_20_10() public {
        address contributor = makeAddr("contributor");
        address(donut).settleDonut(SALE, contributor, 8_000_000, 1_000_001 wei);
        assertEq(donut.claimable(contributor), 700_000);
        assertEq(donut.claimable(vault), 200_000, "reviewer pool");
        assertEq(donut.claimable(Deployments.SAFE), 100_001, "treasury takes the remainder");
    }

    // ── the quote ────────────────────────────────────────────────────────────────────────────────────────────

    /// The legs come from the one scheme (payment-scheme.mjs quoteSale, generated into test/fixtures/bench/venue-pairs.json by
    /// deploy/gen-bench-legs.mjs); on chain only our fee's rule and Σ are checked. The numbers below are the scheme's own rows.
    function test_checkLegs_takes_the_schemes_legs_and_checks_our_fee_and_the_sum() public pure {
        // x402-base → erc8183-base: the venue takes 10 % at source, so 888,888 more must enter it for the doer to keep 8 USDC
        assertTrue(TaifoonCoord.checkLegs(10_888_888, 2_000_000, 0, 888_888, 8_000_000, 0, 2000, 2000));
        // erc8183-base → erc8183-base: grossed up on both sides
        assertTrue(TaifoonCoord.checkLegs(12_098_764, 2_000_000, 1_209_876, 888_888, 8_000_000, 0, 2000, 2000));
        // x402-base → x402-base: no venue takes anything; the buyer pays the list
        assertTrue(TaifoonCoord.checkLegs(10_000_000, 2_000_000, 0, 0, 8_000_000, 0, 2000, 2000));
        // the earlier on-chain formula's answer for the ERC-8183 pair (10,800,000: the fee floored on the net) is not the scheme's
        assertFalse(TaifoonCoord.checkLegs(10_800_000, 2_000_000, 0, 800_000, 8_000_000, 0, 2000, 2000) && 10_800_000 == 10_888_888);
        // our fee off the rule: the check says so
        assertFalse(TaifoonCoord.checkLegs(10_000_001, 2_000_001, 0, 0, 8_000_000, 0, 2000, 2000));
        // the minimum fee: 0.000005 lists at 0.002005; a price of zero lists at the fee's floor
        assertTrue(TaifoonCoord.checkLegs(2005, 2000, 0, 0, 5, 0, 2000, 2000));
        assertTrue(TaifoonCoord.checkLegs(2000, 2000, 0, 0, 0, 0, 2000, 2000));
        // ceil: a seller price of 7.999999 lists at 9.999999 with the fee at the ceiling, 2.000000
        assertTrue(TaifoonCoord.checkLegs(9_999_999, 2_000_000, 0, 0, 7_999_999, 0, 2000, 2000));
    }

    function test_checkLegs_reverts_when_the_legs_do_not_sum() public {
        vm.expectRevert(abi.encodeWithSelector(TaifoonCoord.LegsMismatch.selector, 10_000_001, 10_000_000));
        this.sumOff();
    }

    function sumOff() external pure {
        TaifoonCoord.checkLegs(10_000_000, 2_000_001, 0, 0, 8_000_000, 0, 2000, 2000);
    }

    function test_distributionFor_merges_one_address_and_drops_zero_legs() public pure {
        address v = address(0xA);
        address s = address(0xB);
        ITaifoonPaymentChannel.Distribution memory d = TaifoonCoord.distributionFor(v, address(0xC), address(0xC), s, v, 2_000_000, 1_000_000, 500_000, 8_000_000, 300_000);
        assertEq(d.mode, 1);
        assertEq(d.recipients.length, 3);
        assertEq(d.recipients[0], v);
        assertEq(d.amounts[0], 2_300_000, "fee + the vault's own markup");
        assertEq(d.recipients[1], address(0xC));
        assertEq(d.amounts[1], 1_500_000, "both venue legs, one venue");
        assertEq(d.recipients[2], s);
        assertEq(d.amounts[2], 8_000_000);
        d = TaifoonCoord.distributionFor(v, address(0xC), address(0xD), s, address(0xE), 2_000_000, 0, 0, 8_000_000, 0);
        assertEq(d.recipients.length, 2, "zero legs are dropped");
    }

    function test_quote_four_capabilities_and_the_donuts_value() public {
        (uint256 gas, uint256 value) = quoteContract.quote(ITaifoonPaymentChannel.open.selector, "");
        assertGt(gas, 0);
        assertEq(value, 0);
        (gas, value) = quoteContract.quote(ITaifoonProtocolVerifier.executeVerifiedTransition.selector, "");
        assertGt(gas, 0);
        (gas, value) = quoteContract.quote(ITaifoonPaymentChannel.distribute.selector, "");
        assertGt(gas, 0);
        (gas, value) = quoteContract.quote(ITsulDonut.settle.selector, abi.encode(SALE, address(1), uint256(8_000_000), uint256(123 ether)));
        assertGt(gas, 0);
        assertEq(value, 123 ether, "the fee the donut carries");
        vm.expectRevert(abi.encodeWithSelector(CoordQuote.UnknownCapability.selector, bytes4(0x12345678)));
        quoteContract.quote(bytes4(0x12345678), "");
        quoteContract.setGas(ITaifoonPaymentChannel.open.selector, 1);
        (gas,) = ICoordQuote(address(quoteContract)).quote(ITaifoonPaymentChannel.open.selector, "");
        assertEq(gas, 1);
    }

    // ── the cross-chain release example ──────────────────────────────────────────────────────────────────────

    function _signedRelease(CrossChainRelease rel, uint256 pk, uint64 chainId, bytes32 okh, address to, uint256 amount, uint64 deadline)
        internal
        view
        returns (CrossChainRelease.Release memory r, bytes memory sig)
    {
        r = CrossChainRelease.Release(chainId, okh, to, amount, deadline);
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(pk, rel.releaseDigest(r));
        sig = abi.encodePacked(rr, ss, vv);
    }

    function test_cross_chain_release_happy_path_through_the_verifier() public {
        address buyer = vm.addr(BUYER_PK);
        address reseller = makeAddr("reseller");
        // "chain B": its own anchor and verifier, the same proven transition
        TaifoonSuperrootAnchor anchorB = new TaifoonSuperrootAnchor(address(this), address(this));
        TaifoonProtocolVerifier verifierB = new TaifoonProtocolVerifier(address(this), address(anchorB));
        verifierB.setLambda(COORD, address(lambda));
        verifierB.setAttester(COORD, vault, true);
        verifierB.setOperator(address(this), true);
        CrossChainRelease rel = new CrossChainRelease(address(verifierB), address(usdc), buyer, address(this));
        verifierB.setVendor(address(rel), true);
        usdc.mint(address(rel), 5_000_000);

        (TaifoonTransition.Transition memory t,) = _transition(SALE, lambda.stateOf("settled", "ok"), bytes("x"));
        (ITaifoonProtocolVerifier.ProtocolLeaf memory pl, ITaifoonProtocolVerifier.HistoryProof memory hp,) = _world(t);
        address(anchorB).push(pl.superroot, 1);
        (CrossChainRelease.Release memory r, bytes memory sig) = _signedRelease(rel, BUYER_PK, uint64(block.chainid), SALE, reseller, 500_000, uint64(block.timestamp + 1 hours));
        (bytes32 leaf, bool ok) = address(verifierB).act(COORD, pl, t, hp, address(rel), abi.encodeCall(CrossChainRelease.release, (t, r, sig)));
        assertTrue(ok, "released");
        assertEq(usdc.balanceOf(reseller), 500_000);
        assertTrue(rel.released(leaf));
        // the verifier itself refuses the leaf a second time
        vm.expectRevert(abi.encodeWithSelector(TaifoonProtocolVerifier.AlreadyExecuted.selector, leaf));
        address(verifierB).act(COORD, pl, t, hp, address(rel), abi.encodeCall(CrossChainRelease.release, (t, r, sig)));
        // and a direct call is not the verifier
        vm.expectRevert(CrossChainRelease.NotVerifier.selector);
        rel.release(t, r, sig);
    }

    function test_cross_chain_release_refuses_wrong_chain_expired_wrong_signer_and_replay() public {
        address buyer = vm.addr(BUYER_PK);
        address reseller = makeAddr("reseller");
        LeafStub stub = new LeafStub();
        CrossChainRelease rel = new CrossChainRelease(address(stub), address(usdc), buyer, address(this));
        usdc.mint(address(rel), 5_000_000);
        (TaifoonTransition.Transition memory t,) = _transition(SALE, lambda.stateOf("settled", "ok"), bytes("x"));
        bytes32 leaf = TaifoonTransition.leaf(t);
        uint64 deadline = uint64(block.timestamp + 1 hours);

        (CrossChainRelease.Release memory r, bytes memory sig) = _signedRelease(rel, BUYER_PK, uint64(block.chainid), SALE, reseller, 500_000, deadline);
        vm.prank(address(stub));
        vm.expectRevert(CrossChainRelease.NoProvenLeaf.selector);
        rel.release(t, r, sig);

        stub.set(leaf);
        (r, sig) = _signedRelease(rel, BUYER_PK, uint64(block.chainid + 1), SALE, reseller, 500_000, deadline);
        vm.prank(address(stub));
        vm.expectRevert(abi.encodeWithSelector(CrossChainRelease.WrongChain.selector, uint64(block.chainid + 1)));
        rel.release(t, r, sig);

        (r, sig) = _signedRelease(rel, BUYER_PK, uint64(block.chainid), SALE, reseller, 500_000, uint64(block.timestamp - 1));
        vm.prank(address(stub));
        vm.expectRevert(abi.encodeWithSelector(CrossChainRelease.Expired.selector, uint64(block.timestamp - 1)));
        rel.release(t, r, sig);

        (r, sig) = _signedRelease(rel, 0xDEAD, uint64(block.chainid), SALE, reseller, 500_000, deadline);
        vm.prank(address(stub));
        vm.expectRevert(abi.encodeWithSelector(CrossChainRelease.BadSigner.selector, vm.addr(0xDEAD)));
        rel.release(t, r, sig);

        (r, sig) = _signedRelease(rel, BUYER_PK, uint64(block.chainid), keccak256("another sale"), reseller, 500_000, deadline);
        vm.prank(address(stub));
        vm.expectRevert(abi.encodeWithSelector(CrossChainRelease.WrongSale.selector, SALE, keccak256("another sale")));
        rel.release(t, r, sig);

        bytes32 heldState = lambda.stateOf("settled", "held");
        (TaifoonTransition.Transition memory held,) = _transition(SALE, heldState, bytes("x"));
        stub.set(TaifoonTransition.leaf(held));
        (r, sig) = _signedRelease(rel, BUYER_PK, uint64(block.chainid), SALE, reseller, 500_000, deadline);
        vm.prank(address(stub));
        vm.expectRevert(abi.encodeWithSelector(CrossChainRelease.NotSettledOk.selector, heldState));
        rel.release(held, r, sig);

        stub.set(leaf);
        vm.prank(address(stub));
        rel.release(t, r, sig);
        assertEq(usdc.balanceOf(reseller), 500_000);
        vm.prank(address(stub));
        vm.expectRevert(abi.encodeWithSelector(CrossChainRelease.AlreadyReleased.selector, leaf));
        rel.release(t, r, sig);
    }
}
