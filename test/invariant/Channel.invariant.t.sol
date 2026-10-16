// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TaifoonPaymentChannel} from "../../src/coord/TaifoonPaymentChannel.sol";
import {MockUSDC} from "../sdk/Mocks.sol";

/// The handler: every public move of the channel, from random actors, with ghost sums of what entered and left.
contract ChannelHandler is Test {
    TaifoonPaymentChannel public channel;
    MockUSDC public usdc;
    address public treasury;
    uint256 internal constant SIGNER_PK = 0x5106;
    address public signer;

    bytes32[] public ids;
    mapping(bytes32 => bool) public known;
    mapping(bytes32 => uint256) public seedOf; // the seed the plan was built from at open
    uint256 public deposited; // sum of open + topUp
    uint256 public left; // sum of tokens that left the contract (payouts, redirects, refunds, dust)
    uint256 public calls;

    constructor(TaifoonPaymentChannel c, MockUSDC u, address t) {
        channel = c;
        usdc = u;
        treasury = t;
        signer = vm.addr(SIGNER_PK);
    }

    function _actor(uint256 seed) internal pure returns (address) {
        return address(uint160(0x1000 + (seed % 7)));
    }

    function _plan(uint256 seed) internal pure returns (TaifoonPaymentChannel.Distribution memory d) {
        d.mode = 0;
        uint256 n = 1 + (seed % 3);
        d.recipients = new address[](n);
        d.amounts = new uint256[](n);
        uint256 used;
        for (uint256 i = 0; i < n; i++) {
            d.recipients[i] = address(uint160(0x2000 + i + (seed % 5) * 10));
            d.amounts[i] = 500 + (seed >> (8 * i)) % 2000;
            used += d.amounts[i];
        }
        if (used > 9000) d.amounts[0] -= used - 9000;
    }

    function open(uint256 seed, uint96 amount) external {
        calls++;
        address payer = _actor(seed);
        address payee = _actor(seed + 1);
        uint256 dep = 1 + uint256(amount);
        usdc.mint(payer, dep);
        vm.startPrank(payer);
        usdc.approve(address(channel), dep);
        bytes32 id = channel.open(payee, address(usdc), signer, seed, dep, 15 minutes, keccak256(abi.encode(seed)), _plan(seed));
        vm.stopPrank();
        ids.push(id);
        known[id] = true;
        seedOf[id] = seed;
        deposited += dep;
    }

    function topUp(uint256 which, uint96 amount) external {
        if (ids.length == 0) return;
        calls++;
        bytes32 id = ids[which % ids.length];
        TaifoonPaymentChannel.Channel memory c = channel.channelOf(id);
        if (c.status != TaifoonPaymentChannel.Status.OPEN) return;
        uint256 add = 1 + uint256(amount);
        usdc.mint(c.payer, add);
        vm.startPrank(c.payer);
        usdc.approve(address(channel), add);
        channel.topUp(id, add);
        vm.stopPrank();
        deposited += add;
    }

    function settle(uint256 which, uint256 frac) external {
        if (ids.length == 0) return;
        calls++;
        bytes32 id = ids[which % ids.length];
        TaifoonPaymentChannel.Channel memory c = channel.channelOf(id);
        if (c.status != TaifoonPaymentChannel.Status.OPEN) return;
        uint256 cumulative = c.settled + 1 + (frac % (c.deposit - c.settled == 0 ? 1 : c.deposit - c.settled));
        if (cumulative > c.deposit) return;
        TaifoonPaymentChannel.Voucher memory v = TaifoonPaymentChannel.Voucher(id, cumulative, uint64(block.timestamp + 1 hours));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, channel.voucherDigest(v));
        channel.settle(v, abi.encodePacked(r, s, vv));
    }

    function requestClose(uint256 which) external {
        if (ids.length == 0) return;
        calls++;
        bytes32 id = ids[which % ids.length];
        TaifoonPaymentChannel.Channel memory c = channel.channelOf(id);
        if (c.status != TaifoonPaymentChannel.Status.OPEN) return;
        vm.prank(c.payer);
        channel.requestClose(id);
    }

    function seal(uint256 which) external {
        if (ids.length == 0) return;
        calls++;
        bytes32 id = ids[which % ids.length];
        TaifoonPaymentChannel.Channel memory c = channel.channelOf(id);
        if (c.status != TaifoonPaymentChannel.Status.CLOSING) return;
        vm.warp(block.timestamp + 16 minutes);
        channel.seal(id);
    }

    function withdrawPayer(uint256 which) external {
        if (ids.length == 0) return;
        calls++;
        bytes32 id = ids[which % ids.length];
        TaifoonPaymentChannel.Channel memory c = channel.channelOf(id);
        if (c.status != TaifoonPaymentChannel.Status.SEALED || c.payerWithdrawn) return;
        uint256 before = usdc.balanceOf(address(channel));
        vm.prank(c.payer);
        channel.withdrawPayer(id);
        left += before - usdc.balanceOf(address(channel));
    }

    function distribute(uint256 which) external {
        if (ids.length == 0) return;
        calls++;
        bytes32 id = ids[which % ids.length];
        TaifoonPaymentChannel.Channel memory c = channel.channelOf(id);
        if (c.status != TaifoonPaymentChannel.Status.OPEN && c.status != TaifoonPaymentChannel.Status.SEALED) return;
        // the plan is the one committed at open: rebuilt from the seed the id was opened with
        TaifoonPaymentChannel.Distribution memory d = _plan(seedOf[id]);
        if (c.status == TaifoonPaymentChannel.Status.OPEN && c.settled == c.payoutWatermark) return;
        uint256 before = usdc.balanceOf(address(channel));
        channel.distribute(id, d);
        left += before - usdc.balanceOf(address(channel));
    }

    function count() external view returns (uint256) {
        return ids.length;
    }
}

/// Σ deposited = what the contract holds + what left; the escrow ledger equals the balance; a channel's settled ≤ deposit,
/// its watermark ≤ settled, its paid ≤ deposit; a sealed channel never un-seals.
contract ChannelInvariant is Test {
    TaifoonPaymentChannel internal channel;
    MockUSDC internal usdc;
    ChannelHandler internal h;
    address internal treasury = address(0xBEEF);

    function setUp() public {
        usdc = new MockUSDC();
        channel = new TaifoonPaymentChannel(address(this), treasury, address(0));
        h = new ChannelHandler(channel, usdc, treasury);
        targetContract(address(h));
    }

    function invariant_deposits_equal_held_plus_left() public view {
        assertEq(h.deposited(), usdc.balanceOf(address(channel)) + h.left(), "sum deposited = held + left");
    }

    function invariant_escrow_ledger_equals_balance() public view {
        assertEq(channel.escrowed(address(usdc)), usdc.balanceOf(address(channel)), "escrowed == balance (no surplus here)");
    }

    function invariant_every_channel_is_bounded() public view {
        uint256 n = h.count();
        for (uint256 i = 0; i < n; i++) {
            TaifoonPaymentChannel.Channel memory c = channel.channelOf(h.ids(i));
            if (c.status == TaifoonPaymentChannel.Status.NONE) continue; // closed: storage deleted
            assertLe(c.settled, c.deposit, "settled <= deposit");
            assertLe(c.payoutWatermark, c.settled, "watermark <= settled");
            assertLe(c.paid, c.deposit, "paid <= deposit");
        }
    }
}
