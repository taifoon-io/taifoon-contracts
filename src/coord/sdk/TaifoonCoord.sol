// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TaifoonTransition} from "../../lib/TaifoonTransition.sol";
import {
    ITaifoonSuperrootAnchor,
    ITaifoonProtocolVerifier,
    ITaifoonPaymentChannel,
    ITaifoonWorkflow,
    ITsulDonut
} from "./interface.sol";

/// @title TaifoonCoord — one legible, address-explicit call site per capability of the coord layer (anchor · verifier · channel · workflow · donut)
/// @notice The thin library a contract on any EVM chain calls the coordination layer through (the shape of Rome's
///         `Cpi`: every function takes the target address first, so a call site reads as "which module, which
///         capability, which arguments" and the addresses come from Deployments.sol or a test's fresh deploys).
///         Internal functions: the calls are made by the caller's own frame (msg.sender is the caller), so the
///         payer/payee roles of the channel are the calling contract's.
///
///         Also the pure quote of the layer's one payment scheme (the coord layer's packages/resale/core/
///         payment-scheme.mjs, _ONE_PAYMENT_SCHEME_v1_): `legsOf` gives the legs a buyer's payment leaves as, and
///         `distributionFor` turns them into the mode-1 Distribution a channel is opened with, so what the buyer
///         pays leaves again as named legs that sum to the payment exactly.
library TaifoonCoord {
    uint256 internal constant BPS = 10_000;

    error FeeTakesEverything(uint16 ourFeeBps);
    error LegsMismatch(uint256 sum, uint256 priceToBuyer);

    // ── anchor ─────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Whether `root` is a superroot this chain's anchor has seen.
    function anchored(address anchor, bytes32 root) internal view returns (bool) {
        return ITaifoonSuperrootAnchor(anchor).isKnownSuperroot(root);
    }

    /// @notice The freshest superroot on this chain, its batch id and age.
    function current(address anchor) internal view returns (bytes32 root, uint64 batchId, uint64 ageSecs) {
        return ITaifoonSuperrootAnchor(anchor).current();
    }

    /// @notice Push a superroot (the caller must be the anchor's updater or owner).
    function push(address anchor, bytes32 root, uint64 batchId) internal {
        ITaifoonSuperrootAnchor(anchor).pushSuperroot(root, batchId);
    }

    // ── verifier ───────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Prove transitions of a protocol under the superroot; returns their leaves.
    function prove(
        address verifier,
        bytes32 protocolId,
        ITaifoonProtocolVerifier.ProtocolLeaf memory pl,
        TaifoonTransition.Transition[] memory ts,
        ITaifoonProtocolVerifier.HistoryProof memory hp
    ) internal returns (bytes32[] memory leaves) {
        return ITaifoonProtocolVerifier(verifier).verifyTransitions(protocolId, pl, ts, hp);
    }

    /// @notice Prove an order's current state.
    function proveOrder(
        address verifier,
        bytes32 protocolId,
        ITaifoonProtocolVerifier.ProtocolLeaf memory pl,
        bytes32 orderKeyHash,
        ITaifoonProtocolVerifier.StateProof memory sp
    ) internal returns (bool) {
        return ITaifoonProtocolVerifier(verifier).verifyOrderState(protocolId, pl, orderKeyHash, sp);
    }

    /// @notice Prove one transition and act on it: the verifier calls `vendor` with `callData` while `currentLeaf()`
    ///         names the transition (= executeVerifiedTransition; the caller must be an operator).
    function act(
        address verifier,
        bytes32 protocolId,
        ITaifoonProtocolVerifier.ProtocolLeaf memory pl,
        TaifoonTransition.Transition memory t,
        ITaifoonProtocolVerifier.HistoryProof memory hp,
        address vendor,
        bytes memory callData
    ) internal returns (bytes32 leaf, bool success) {
        return ITaifoonProtocolVerifier(verifier).executeVerifiedTransition(protocolId, pl, t, hp, vendor, callData);
    }

    /// @notice Re-check an attested, proven transition from its signature and payload.
    function checkAttestation(
        address verifier,
        TaifoonTransition.Transition memory t,
        bytes memory payload,
        bytes memory signature,
        uint64 issuedAt
    ) internal view returns (bool) {
        return ITaifoonProtocolVerifier(verifier).checkAttestation(t, payload, signature, issuedAt);
    }

    // ── payment channel ────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Open a channel as the payer (the caller must have approved `deposit` of `token` to the channel).
    function open(
        address channel,
        address payee,
        address token,
        address authorizedSigner,
        uint256 salt,
        uint256 deposit,
        uint32 gracePeriod,
        bytes32 orderKeyHash,
        ITaifoonPaymentChannel.Distribution memory d
    ) internal returns (bytes32 channelId) {
        return ITaifoonPaymentChannel(channel).open(payee, token, authorizedSigner, salt, deposit, gracePeriod, orderKeyHash, d);
    }

    /// @notice Advance a channel's settled watermark with a voucher.
    function settle(address channel, ITaifoonPaymentChannel.Voucher memory v, bytes memory signature) internal {
        ITaifoonPaymentChannel(channel).settle(v, signature);
    }

    /// @notice Add to a channel's escrow (payer).
    function topUp(address channel, bytes32 channelId, uint256 amount) internal {
        ITaifoonPaymentChannel(channel).topUp(channelId, amount);
    }

    /// @notice Start the grace period (payer).
    function requestClose(address channel, bytes32 channelId) internal {
        ITaifoonPaymentChannel(channel).requestClose(channelId);
    }

    /// @notice Seal after the grace period (anyone).
    function seal(address channel, bytes32 channelId) internal {
        ITaifoonPaymentChannel(channel).seal(channelId);
    }

    /// @notice Cooperative close with an optional final voucher (payee; empty signature = none).
    function settleAndSeal(address channel, bytes32 channelId, ITaifoonPaymentChannel.Voucher memory v, bytes memory signature)
        internal
    {
        ITaifoonPaymentChannel(channel).settleAndSeal(channelId, v, signature);
    }

    /// @notice Take back the unspent deposit once the channel is sealed (payer, once).
    function withdrawPayer(address channel, bytes32 channelId) internal {
        ITaifoonPaymentChannel(channel).withdrawPayer(channelId);
    }

    /// @notice Reveal the plan and pay it (anyone).
    function distribute(address channel, bytes32 channelId, ITaifoonPaymentChannel.Distribution memory d) internal {
        ITaifoonPaymentChannel(channel).distribute(channelId, d);
    }

    /// @notice Release a channel whose sale was proven `settled:ok` (anyone).
    function sealProven(address channel, bytes32 channelId) internal {
        ITaifoonPaymentChannel(channel).sealProven(channelId);
    }

    // ── workflow ───────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Commit a workflow: the state of every step and its binding (once per spec hash; anyone).
    function registerWorkflow(address workflow, bytes32 specHash, bytes32[] memory states, ITaifoonWorkflow.Binding[] memory bindings)
        internal
        returns (bytes32 wfId)
    {
        return ITaifoonWorkflow(workflow).register(specHash, states, bindings);
    }

    /// @notice Advance an order one step with the proof of its transition (the binding fires: a channel release, a
    ///         vendor call, or nothing); `args` = abi.encode(channelId) for a channel step, the vendor calldata, or empty.
    function advance(
        address workflow,
        bytes32 wfId,
        bytes32 protocolId,
        ITaifoonProtocolVerifier.ProtocolLeaf memory pl,
        TaifoonTransition.Transition memory t,
        ITaifoonProtocolVerifier.HistoryProof memory hp,
        bytes memory args
    ) internal returns (uint32 step, bytes32 leaf) {
        return ITaifoonWorkflow(workflow).advance(wfId, protocolId, pl, t, hp, args);
    }

    /// @notice Where an order stands in a workflow.
    function instanceOf(address workflow, bytes32 wfId, bytes32 orderKeyHash) internal view returns (uint32 next, uint256 total, bool done) {
        return ITaifoonWorkflow(workflow).instanceOf(wfId, orderKeyHash);
    }

    // ── donut ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Discharge the TSUL donut on a fee: `fee` wei are sent and split 70/20/10 (the caller must be an
    ///         authorized settler of the donut).
    function settleDonut(address donut, bytes32 bountyId, address contributor, uint256 callRevenue, uint256 fee) internal {
        ITsulDonut(donut).settle{value: fee}(bountyId, contributor, callRevenue);
    }

    // ── the quote: one payment scheme for every pair of venues ────────────────────────────────────────────────

    /// @notice The legs of one sale are QUOTED OFF-CHAIN by the one payment scheme (the coord layer's
    ///         packages/resale/core/payment-scheme.mjs `quoteSale`, _ONE_PAYMENT_SCHEME_v1_: the venues' fees as read on
    ///         their contracts, grossed up on a venue that takes its fee at source so the doer still receives its price;
    ///         deploy/gen-bench-legs.mjs writes them into the bench fixture). On chain only two things are computed: our
    ///         fee's rule (`listPriceOf` / `feeOf`, the twin of the scheme's `listPriceOf`) and the sum. This checks the
    ///         legs a caller holds: `priceToBuyer = ourFee + venueIn + venueOut + sellerShare + markup`, to the unit, and
    ///         our fee = the wall rule's fee on the seller's price. An earlier `legsOf` computed the venue fees here,
    ///         floored on the net: it disagreed with the scheme on 24 of the bench's 30 pairs and was removed (2026-10-14).
    function checkLegs(
        uint256 priceToBuyer,
        uint256 ourFee,
        uint256 venueIn,
        uint256 venueOut,
        uint256 sellerShare,
        uint256 markup,
        uint16 ourFeeBps,
        uint256 ourFeeMin
    ) internal pure returns (bool) {
        uint256 sum = ourFee + venueIn + venueOut + sellerShare + markup;
        if (sum != priceToBuyer) revert LegsMismatch(sum, priceToBuyer);
        return listPriceOf(sellerShare, ourFeeBps, ourFeeMin) - sellerShare == ourFee;
    }

    /// @notice The list price of a seller price: the smallest `L` with `L − feeOf(L) ≥ sellerPrice` (what the buyer
    ///         pays where no venue takes anything). A price of zero lists at the fee's floor.
    function listPriceOf(uint256 sellerPrice, uint16 ourFeeBps, uint256 ourFeeMin) internal pure returns (uint256 L) {
        if (ourFeeBps >= BPS) revert FeeTakesEverything(ourFeeBps);
        L = sellerPrice + ourFeeMin;
        if (feeOf(L, ourFeeBps, ourFeeMin) <= ourFeeMin) return L;
        L = (sellerPrice * BPS) / (BPS - ourFeeBps);
        if (L < sellerPrice + ourFeeMin) L = sellerPrice + ourFeeMin;
        while (L - feeOf(L, ourFeeBps, ourFeeMin) < sellerPrice) L++;
        while (L > sellerPrice + ourFeeMin && (L - 1) - feeOf(L - 1, ourFeeBps, ourFeeMin) >= sellerPrice) L--;
    }

    /// @notice Our fee on a list price: `max(ceil(list·bps/10000), min)`, never above the list price.
    function feeOf(uint256 list, uint16 ourFeeBps, uint256 ourFeeMin) internal pure returns (uint256 f) {
        f = (list * ourFeeBps + (BPS - 1)) / BPS;
        if (f < ourFeeMin) f = ourFeeMin;
        if (f > list) f = list;
    }

    /// @notice The mode-1 Distribution of a sale's legs, ready for `open`: vault ← ourFee, the buying venue ← venueIn,
    ///         the selling venue ← venueOut, seller ← sellerShare, reseller ← markup. Legs to one address are merged,
    ///         zero legs dropped (the channel refuses both duplicates and zero amounts).
    function distributionFor(
        address vault,
        address venueInAddr,
        address venueOutAddr,
        address seller,
        address reseller,
        uint256 ourFee,
        uint256 venueIn,
        uint256 venueOut,
        uint256 sellerShare,
        uint256 markup
    ) internal pure returns (ITaifoonPaymentChannel.Distribution memory d) {
        address[5] memory to = [vault, venueInAddr, venueOutAddr, seller, reseller];
        uint256[5] memory amt = [ourFee, venueIn, venueOut, sellerShare, markup];
        address[] memory recipients = new address[](5);
        uint256[] memory amounts = new uint256[](5);
        uint256 n;
        for (uint256 i = 0; i < 5; i++) {
            if (amt[i] == 0) continue;
            uint256 j;
            while (j < n && recipients[j] != to[i]) j++;
            if (j == n) {
                recipients[n] = to[i];
                n++;
            }
            amounts[j] += amt[i];
        }
        assembly ("memory-safe") {
            mstore(recipients, n)
            mstore(amounts, n)
        }
        d.mode = 1;
        d.recipients = recipients;
        d.amounts = amounts;
    }
}
