// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TaifoonCoord} from "../TaifoonCoord.sol";
import {ITaifoonProtocolVerifier, ITaifoonPaymentChannel} from "../interface.sol";
import {TaifoonAddresses} from "../TaifoonAddresses.sol";
import {IJevDecisionLog} from "../../../interfaces/IJevDecisionLog.sol";

/// @notice The ERC-20 surface the job needs.
interface IERC20Job {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title AgentJob — hire an agent, pay it and its reseller by the Taifoon payment scheme, release on Jev or a proof
/// @notice The smallest contract that coordinates with the Taifoon layer:
///         (a) `post` — a buyer hires an agent through a reseller. The price is computed by the payment scheme's on-chain
///             rule (`TaifoonCoord.listPriceOf`: our fee on the seller's price) plus the reseller's markup, and the legs are
///             checked to the unit (`TaifoonCoord.checkLegs`). The buyer's tokens are escrowed here.
///         (b) `releaseOnJev` — pays the legs once Jev's decision on this job is in the Jev decision log, recorded by Jev's
///             recorder, with at least the confidence the job asked for.
///         (c) `releaseOnProof` — or pays once the Taifoon verifier proves the job's order reached the `delivered:ok` state
///             under the superroot (a proof the coord API serves at /v1/protocol/:protocol/order/:key).
///         The legs go out by `TaifoonCoord.distributionFor` (our fee to the vault, the seller's share, the reseller's
///         markup). `refund` returns the escrow to the buyer after the deadline when neither condition arrived.
contract AgentJob {
    struct Job {
        address buyer;
        address agent;
        address reseller;
        uint256 sellerPrice;
        uint256 ourFee;
        uint256 markup;
        bytes32 orderKeyHash;
        uint64 deadline;
        uint16 minConfidenceBps;
        uint8 state; // 1 posted, 2 paid, 3 refunded
    }

    /// keccak256("verdict"): the kind Jev records a verdict under.
    bytes32 public constant VERDICT_KIND = keccak256("verdict");
    /// The state a delivered order is proven in.
    bytes32 public constant DELIVERED_OK = keccak256(abi.encodePacked("delivered", ":", "ok"));

    address public immutable token;
    address public immutable vault;
    uint16 public immutable ourFeeBps;
    uint256 public immutable ourFeeMin;
    IJevDecisionLog public immutable decisionLog;
    address public immutable jevRecorder;
    address public immutable verifier;
    bytes32 public immutable protocolId;

    mapping(bytes32 => Job) public jobs;

    event Posted(bytes32 indexed jobId, address indexed agent, address indexed reseller, uint256 priceToBuyer, bytes32 orderKeyHash);
    event Paid(bytes32 indexed jobId, uint256 ourFee, uint256 sellerShare, uint256 markup, bytes32 evidence);
    event Refunded(bytes32 indexed jobId);

    error JobExists(bytes32 jobId);
    error NotPosted(bytes32 jobId);
    error NoJevVerdict(bytes32 jobId);
    error NotJevsRecord(address recorder);
    error LowConfidence(uint16 got, uint16 wanted);
    error NotDelivered(bytes32 jobId);
    error TooEarly(uint64 deadline);
    error TransferFailed();

    constructor(
        address _token,
        address _vault,
        uint16 _ourFeeBps,
        uint256 _ourFeeMin,
        address _decisionLog,
        address _jevRecorder,
        address _verifier,
        bytes32 _protocolId
    ) {
        token = _token;
        vault = _vault;
        ourFeeBps = _ourFeeBps;
        ourFeeMin = _ourFeeMin;
        decisionLog = IJevDecisionLog(_decisionLog);
        jevRecorder = _jevRecorder;
        verifier = _verifier;
        protocolId = _protocolId;
    }

    /// @notice The price the buyer pays for a seller price and a markup, and our fee in it.
    function priceOf(uint256 sellerPrice, uint256 markup) public view returns (uint256 priceToBuyer, uint256 ourFee) {
        ourFee = TaifoonCoord.listPriceOf(sellerPrice, ourFeeBps, ourFeeMin) - sellerPrice;
        priceToBuyer = ourFee + sellerPrice + markup;
    }

    /// @notice (a) Hire `agent` through `reseller`; the caller pays `priceOf(sellerPrice, markup)` (approve it first).
    function post(
        bytes32 jobId,
        address agent,
        address reseller,
        uint256 sellerPrice,
        uint256 markup,
        string calldata orderKey,
        uint64 deadline,
        uint16 minConfidenceBps
    ) external returns (uint256 priceToBuyer) {
        if (jobs[jobId].state != 0) revert JobExists(jobId);
        uint256 ourFee;
        (priceToBuyer, ourFee) = priceOf(sellerPrice, markup);
        // the legs are the scheme's: no venue fee on a direct hire; Σ legs = price, our fee by the wall rule
        TaifoonCoord.checkLegs(priceToBuyer, ourFee, 0, 0, sellerPrice, markup, ourFeeBps, ourFeeMin);
        bytes32 okh = keccak256(bytes(orderKey));
        jobs[jobId] = Job(msg.sender, agent, reseller, sellerPrice, ourFee, markup, okh, deadline, minConfidenceBps, 1);
        if (!IERC20Job(token).transferFrom(msg.sender, address(this), priceToBuyer)) revert TransferFailed();
        emit Posted(jobId, agent, reseller, priceToBuyer, okh);
    }

    /// @notice (b) Pay the legs once Jev recorded its decision on this job (subject = this contract's job on this chain).
    function releaseOnJev(bytes32 jobId) external {
        Job storage j = _posted(jobId);
        IJevDecisionLog.Decision memory d = decisionLog.latest(decisionLog.subjectOf(block.chainid, address(this), jobId));
        if (d.at == 0 || d.kind != VERDICT_KIND) revert NoJevVerdict(jobId);
        if (d.recorder != jevRecorder) revert NotJevsRecord(d.recorder);
        if (d.confidenceBps < j.minConfidenceBps) revert LowConfidence(d.confidenceBps, j.minConfidenceBps);
        _pay(jobId, j, d.digest);
    }

    /// @notice (c) Pay the legs once the verifier proves the job's order is `delivered:ok` under the superroot.
    function releaseOnProof(bytes32 jobId, ITaifoonProtocolVerifier.ProtocolLeaf calldata pl, ITaifoonProtocolVerifier.StateProof calldata sp)
        external
    {
        Job storage j = _posted(jobId);
        if (sp.toState != DELIVERED_OK) revert NotDelivered(jobId);
        if (!TaifoonCoord.proveOrder(verifier, protocolId, pl, j.orderKeyHash, sp)) revert NotDelivered(jobId);
        _pay(jobId, j, pl.superroot);
    }

    /// @notice Return the escrow to the buyer after the deadline when neither release came.
    function refund(bytes32 jobId) external {
        Job storage j = _posted(jobId);
        if (block.timestamp <= j.deadline) revert TooEarly(j.deadline);
        j.state = 3;
        if (!IERC20Job(token).transfer(j.buyer, j.ourFee + j.sellerPrice + j.markup)) revert TransferFailed();
        emit Refunded(jobId);
    }

    function _posted(bytes32 jobId) private view returns (Job storage j) {
        j = jobs[jobId];
        if (j.state != 1) revert NotPosted(jobId);
    }

    function _pay(bytes32 jobId, Job storage j, bytes32 evidence) private {
        j.state = 2;
        ITaifoonPaymentChannel.Distribution memory d =
            TaifoonCoord.distributionFor(vault, address(0), address(0), j.agent, j.reseller, j.ourFee, 0, 0, j.sellerPrice, j.markup);
        for (uint256 i = 0; i < d.recipients.length; i++) {
            if (!IERC20Job(token).transfer(d.recipients[i], d.amounts[i])) revert TransferFailed();
        }
        emit Paid(jobId, j.ourFee, j.sellerPrice, j.markup, evidence);
    }

    /// @notice Where this job's dependencies are live: the Jev log on this chain and the verifier module.
    function liveHere() external view returns (bool verifierLive) {
        verifierLive = TaifoonAddresses.isLive(block.chainid, TaifoonAddresses.Module.Verifier);
    }
}
