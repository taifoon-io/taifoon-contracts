// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentJob} from "../../src/coord/sdk/examples/AgentJob.sol";
import {TaifoonAddresses} from "../../src/coord/sdk/TaifoonAddresses.sol";
import {Deployments} from "../../src/coord/sdk/Deployments.sol";
import {IJevDecisionLog} from "../../src/interfaces/IJevDecisionLog.sol";
import {IJudgeAdapterV5} from "../../src/interfaces/IJudgeAdapterV5.sol";
import {ITaifoonProtocolVerifier} from "../../src/coord/sdk/interface.sol";
import {MockUSDC} from "./Mocks.sol";

/// A decision log with the deployed log's semantics (append-only, anyone records, subject = keccak(chainId, at, ref)).
contract LogStub {
    mapping(bytes32 => IJevDecisionLog.Decision[]) internal _log;
    function subjectOf(uint256 chainId, address at, bytes32 ref) public pure returns (bytes32) { return keccak256(abi.encode(chainId, at, ref)); }
    function record(bytes32 s, bytes32 kind, bytes32 digest, uint16 c, string calldata model, string calldata uri) external returns (uint256) {
        _log[s].push(IJevDecisionLog.Decision(msg.sender, kind, digest, c, uint64(block.timestamp), model, uri));
        return _log[s].length - 1;
    }
    function latest(bytes32 s) external view returns (IJevDecisionLog.Decision memory d) { if (_log[s].length > 0) d = _log[s][_log[s].length - 1]; }
}

/// A verifier that proves exactly one (orderKeyHash, toState).
contract VerifierStub {
    bytes32 public okh; bytes32 public st;
    function set(bytes32 o, bytes32 s) external { okh = o; st = s; }
    function verifyOrderState(bytes32, ITaifoonProtocolVerifier.ProtocolLeaf calldata, bytes32 o, ITaifoonProtocolVerifier.StateProof calldata sp) external view returns (bool) {
        return o == okh && sp.toState == st;
    }
}

contract AgentJobTest is Test {
    MockUSDC usdc; LogStub jlog; VerifierStub ver; AgentJob job;
    address buyer = address(0xB0B); address agent = address(0xA6E); address reseller = address(0x5E11); address vault = address(0x7A17);
    address jev = address(0x7E7);

    function setUp() public {
        usdc = new MockUSDC(); jlog = new LogStub(); ver = new VerifierStub();
        job = new AgentJob(address(usdc), vault, 500, 10_000, address(jlog), jev, address(ver), keccak256("taifoon_coord"));
        usdc.mint(buyer, 100e6);
    }

    function _post(bytes32 id) internal returns (uint256 price) {
        (price,) = job.priceOf(10e6, 1e6);
        vm.startPrank(buyer); usdc.approve(address(job), price);
        job.post(id, agent, reseller, 10e6, 1e6, "sale:8453:0xa", uint64(block.timestamp + 1 days), 7_000);
        vm.stopPrank();
    }

    function test_legs_sum_to_price_and_pay_on_jev() public {
        uint256 price = _post("j1");
        (, uint256 fee) = job.priceOf(10e6, 1e6);
        assertEq(price, fee + 10e6 + 1e6);
        bytes32 s_j1 = jlog.subjectOf(block.chainid, address(job), "j1"); vm.prank(jev); jlog.record(s_j1, keccak256("verdict"), bytes32("d"), 9_000, "jev", "uri");
        job.releaseOnJev("j1");
        assertEq(usdc.balanceOf(agent), 10e6); assertEq(usdc.balanceOf(reseller), 1e6); assertEq(usdc.balanceOf(vault), fee);
        assertEq(usdc.balanceOf(address(job)), 0);
    }

    function test_refuses_a_record_that_is_not_jevs() public {
        _post("j2");
        jlog.record(jlog.subjectOf(block.chainid, address(job), "j2"), keccak256("verdict"), bytes32("d"), 9_000, "x", "u");
        vm.expectRevert(abi.encodeWithSelector(AgentJob.NotJevsRecord.selector, address(this)));
        job.releaseOnJev("j2");
    }

    function test_refuses_low_confidence() public {
        _post("j3");
        bytes32 s_j3 = jlog.subjectOf(block.chainid, address(job), "j3"); vm.prank(jev); jlog.record(s_j3, keccak256("verdict"), bytes32("d"), 5_000, "jev", "u");
        vm.expectRevert(abi.encodeWithSelector(AgentJob.LowConfidence.selector, uint16(5_000), uint16(7_000)));
        job.releaseOnJev("j3");
    }

    function test_pays_on_a_proven_delivery() public {
        _post("j4");
        ver.set(keccak256(bytes("sale:8453:0xa")), job.DELIVERED_OK());
        ITaifoonProtocolVerifier.ProtocolLeaf memory pl; ITaifoonProtocolVerifier.StateProof memory sp; sp.toState = job.DELIVERED_OK();
        job.releaseOnProof("j4", pl, sp);
        assertEq(usdc.balanceOf(agent), 10e6);
    }

    function test_refund_after_deadline_only() public {
        uint256 price = _post("j5");
        vm.expectRevert(); job.refund("j5");
        vm.warp(block.timestamp + 1 days + 1); job.refund("j5");
        assertEq(usdc.balanceOf(buyer), 100e6 - price + price);
    }

    function test_addresses_say_where_modules_landed() public pure {
        assertTrue(TaifoonAddresses.isLive(8453, TaifoonAddresses.Module.Verifier));
        assertFalse(TaifoonAddresses.isLive(42161, TaifoonAddresses.Module.Verifier));
        assertEq(TaifoonAddresses.requireLive(8453, TaifoonAddresses.Module.Anchor), Deployments.ANCHOR);
        assertEq(TaifoonAddresses.judgeAdapterV5(8453), 0x5242dE388a846d16641744dEB095eD63990E7be8);
    }
}

/// Base fork: the live Jev decision log and JudgeAdapterV5. Runs when BASE_RPC_URL is set (else skipped).
contract AgentJobBaseForkTest is Test {
    function test_fork_base_live_jev_and_usdc() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address logAddr = TaifoonAddresses.jevDecisionLog(8453);
        IJudgeAdapterV5 v5 = IJudgeAdapterV5(TaifoonAddresses.judgeAdapterV5(8453));
        assertEq(v5.decisionLog(), logAddr, "V5 anchors to the published log");
        assertTrue(v5.isAnchorRecorder(TaifoonAddresses.JEV_RECORDER), "Jev's recorder is V5's anchor recorder");
        assertTrue(TaifoonAddresses.isLive(8453, TaifoonAddresses.Module.Verifier));
        AgentJob job = new AgentJob(usdc, Deployments.VAULT, 500, 10_000, logAddr, TaifoonAddresses.JEV_RECORDER, Deployments.VERIFIER, keccak256("taifoon_coord"));
        address buyer = makeAddr("buyer"); address agent = makeAddr("agent"); address reseller = makeAddr("reseller");
        (uint256 price, uint256 fee) = job.priceOf(10e6, 1e6);
        deal(usdc, buyer, price);
        vm.startPrank(buyer);
        (bool ok,) = usdc.call(abi.encodeWithSignature("approve(address,uint256)", address(job), price)); assertTrue(ok);
        job.post("fork-1", agent, reseller, 10e6, 1e6, "sale:8453:fork-1", uint64(block.timestamp + 1 days), 7_000);
        vm.stopPrank();
        // Jev's recorder records the verdict in the LIVE log (the fork lets us act as it; on chain only Jev's key can)
        IJevDecisionLog dlog = IJevDecisionLog(logAddr);
        bytes32 sf = dlog.subjectOf(8453, address(job), "fork-1");
        vm.prank(TaifoonAddresses.JEV_RECORDER);
        dlog.record(sf, keccak256("verdict"), bytes32("digest"), 9_500, "jev", "fork");
        uint256 v0 = _bal(usdc, Deployments.VAULT);
        job.releaseOnJev("fork-1");
        assertEq(_bal(usdc, agent), 10e6); assertEq(_bal(usdc, reseller), 1e6); assertEq(_bal(usdc, Deployments.VAULT) - v0, fee);
    }
    function _bal(address t, address a) internal view returns (uint256 b) { (, bytes memory r) = t.staticcall(abi.encodeWithSignature("balanceOf(address)", a)); b = abi.decode(r, (uint256)); }
}
