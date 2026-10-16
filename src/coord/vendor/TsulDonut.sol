// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TsulDonut
 * @notice The on-chain enforcement layer for TSUL clause 4 — the "donut".
 *
 * LICENSE.md makes this a condition of use, not a convention:
 *
 *   "A 49 bps skim of every settled call is routed through
 *    BuildersRegistry.recordRevenueTouch() and split: 70% to the contributor
 *    whose adapter routed the value, 20% to the reviewer agents that certified
 *    it, 10% to the ecosystem treasury."
 *
 * The 70/20/10 SPLIT is the substance and is enforced here exactly. The
 * "49 bps" is not — see the note on the split constants: it is a competitor
 * benchmark that drifted into the licence, and nothing we ship charges it.
 *
 * Two facts about the existing implementation forced this to be a new layer
 * rather than a call added to the router:
 *
 *   1. `BuildersRegistry.recordRevenueTouch(bytes32,address,uint256)` is
 *      `onlyOracle`. A router cannot call it mid-settlement, so the donut
 *      cannot be discharged by simply invoking it from the fee path.
 *   2. That function does NOT perform the 70/20/10 split. It accrues
 *      `callRevenue * b.shareBps / 10000` to ONE contributor. The split named
 *      in the licence existed only in prose — nowhere on chain.
 *
 * So this contract owns the split, and is the single seam every value-routing
 * contract calls. It is deliberately NOT a fork of BuildersRegistry: the
 * registry keeps owning bounty lifecycle and contributor claims, and remains
 * the accounting sink this layer reports into.
 *
 * Design notes:
 *   - `settle()` is payable and splits the received value in one transaction.
 *     Atomic beats eventually-consistent for a licence obligation: an
 *     oracle-relayed donut is one dead relayer away from silently not paying.
 *   - Callers must be authorized. An open `settle()` would let anyone mint
 *     accrual events and poison the reviewer/treasury accounting — the same
 *     "anyone can write a reported number" defect found in
 *     SurgeProofAnchor.markProven and AdapterRegistry.recordExecution.
 *   - Payouts are pull-based (`claim()`), not push. A push to three recipients
 *     inside a swap lets any one of them revert the whole settlement, and one
 *     of them is a Gnosis Safe whose receive costs more than a 2300-gas
 *     stipend.
 *   - The council Safe owns it from block one, with a two-step transfer.
 */

interface IBuildersRegistry {
    function recordRevenueTouch(bytes32 id, address contributor, uint256 callRevenue) external;
}

contract TsulDonut {
    // ─── TSUL clause 4: the SPLIT is the obligation ──────────────────
    //
    // 70/20/10 is fixed and non-negotiable — it is what the licence actually
    // promises contributors, reviewers and the treasury, and every implemented
    // measure is expressed against it.
    //
    // The licence's "49 bps" is NOT adopted here, deliberately. That figure
    // traces to SOLVER_GITHUB_ISSUES.md / TAIFOON_SOLVER_MASTER_PLAN.md, where
    // it is LiFi's observed protocol fee — a competitor benchmark used for
    // revenue modelling. It drifted into LICENSE.md as though it were our own
    // rate. Nothing in this codebase charges 49 bps: SurgeFeeManager takes
    // SURGE_FEE_BPS = 5, the BTC bridge adapter takes SOLVER_FEE_BPS = 10, and
    // adapters are capped at MAX_ADAPTER_FEE_BPS = 50. Hard-coding 49 bps here
    // would mean the donut alone charged ~10x the entire Surge fee, which no
    // route could bear.
    //
    // So this contract does NOT invent a skim rate. The caller states the fee
    // it actually charged and the donut splits THAT 70/20/10. The obligation
    // the licence is protecting — contributors get 70% of protocol revenue —
    // is preserved exactly, and it composes with any fee schedule instead of
    // fighting one.
    uint16 public constant CONTRIBUTOR_BPS = 7000; // 70% of the fee
    uint16 public constant REVIEWER_BPS    = 2000; // 20%
    uint16 public constant TREASURY_BPS    = 1000; // 10%

    address public owner;
    address public pendingOwner;

    /// Ecosystem treasury — the 10% leg.
    address public treasury;
    /// Reviewer pool — the 20% leg. Reviewer agents are identified in the
    /// registry by slug, not by address, so there is no per-agent address to
    /// pay at settlement time. The pool accrues and is distributed by slug
    /// out of band rather than guessing an address here.
    address public reviewerPool;

    /// BuildersRegistry, kept as the accounting sink named by the licence.
    /// Optional: if unset, the split still happens and is evented — the donut
    /// must never be skipped just because the sink is being migrated.
    IBuildersRegistry public registry;

    /// Contracts permitted to settle. The Surge router, bridges, adapters.
    mapping(address => bool) public authorizedSettlers;

    /// Pull-based balances.
    mapping(address => uint256) public claimable;

    uint256 public totalSettled;
    uint256 public totalDonut;

    event Settled(
        address indexed settler,
        bytes32 indexed bountyId,
        address indexed contributor,
        uint256 callRevenue,
        uint256 fee,
        uint256 toContributor,
        uint256 toReviewers,
        uint256 toTreasury
    );
    event Claimed(address indexed who, uint256 amount);
    event SettlerSet(address indexed settler, bool authorized);
    event TreasurySet(address indexed from, address indexed to);
    event ReviewerPoolSet(address indexed from, address indexed to);
    event RegistrySet(address indexed from, address indexed to);
    event RegistryTouchFailed(bytes32 indexed bountyId, address indexed contributor);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotPendingOwner();
    error NotAuthorizedSettler();
    error OwnerIsZero();
    error TreasuryIsZero();
    error ReviewerPoolIsZero();
    error NothingToClaim();
    error ClaimFailed(address to);
    error NoFeeSent();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(address _owner, address _treasury, address _reviewerPool, address _registry) {
        if (_owner == address(0)) revert OwnerIsZero();
        if (_treasury == address(0)) revert TreasuryIsZero();
        if (_reviewerPool == address(0)) revert ReviewerPoolIsZero();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
        treasury = _treasury;
        emit TreasurySet(address(0), _treasury);
        reviewerPool = _reviewerPool;
        emit ReviewerPoolSet(address(0), _reviewerPool);
        registry = IBuildersRegistry(_registry);
        emit RegistrySet(address(0), _registry);
    }

    // ─── The donut ───────────────────────────────────────────────────
    /**
     * Settle a routed call and discharge the TSUL donut in the same tx.
     *
     * The caller sends the fee it ACTUALLY charged as `msg.value`; this splits
     * that 70/20/10. It does not compute a skim of its own — see the note on
     * the split constants for why the licence's 49 bps is not adopted.
     *
     * @param bountyId    bounty the routing adapter merged under (registry key)
     * @param contributor the contributor whose adapter routed the value
     * @param callRevenue notional value routed. Reported for accounting and
     *                    passed to the registry; NOT used to derive the fee.
     */
    function settle(bytes32 bountyId, address contributor, uint256 callRevenue)
        external
        payable
    {
        if (!authorizedSettlers[msg.sender]) revert NotAuthorizedSettler();
        // A settlement carrying no fee is a caller bug, not a free pass: it
        // would emit a Settled event attesting a donut that never happened.
        if (msg.value == 0) revert NoFeeSent();

        uint256 fee = msg.value;
        uint256 toContributor = (fee * CONTRIBUTOR_BPS) / 10000;
        uint256 toReviewers   = (fee * REVIEWER_BPS)    / 10000;
        // Treasury takes the remainder, so integer division can never strand
        // wei and the three legs always sum to msg.value exactly.
        uint256 toTreasury    = fee - toContributor - toReviewers;

        if (contributor != address(0)) {
            claimable[contributor] += toContributor;
        } else {
            // No contributor attributed: their leg goes to the treasury rather
            // than being burned or silently retained.
            toTreasury += toContributor;
            toContributor = 0;
        }
        claimable[reviewerPool] += toReviewers;
        claimable[treasury]     += toTreasury;

        totalSettled += callRevenue;
        totalDonut   += fee;

        // Report into the registry the licence names. Best-effort: a revert
        // there (unmerged bounty, oracle not yet repointed, registry mid
        // migration) must NOT roll back a settlement whose donut has already
        // been split correctly here. The failure is evented, not swallowed.
        if (address(registry) != address(0) && contributor != address(0)) {
            try registry.recordRevenueTouch(bountyId, contributor, callRevenue) {
                // accounted
            } catch {
                emit RegistryTouchFailed(bountyId, contributor);
            }
        }

        emit Settled(
            msg.sender, bountyId, contributor,
            callRevenue, fee, toContributor, toReviewers, toTreasury
        );
    }

    // ─── Claims (pull, never push) ───────────────────────────────────
    function claim() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        // Zero BEFORE transferring: this is the reentrancy seam.
        claimable[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert ClaimFailed(msg.sender);
        emit Claimed(msg.sender, amount);
    }

    // ─── Admin ───────────────────────────────────────────────────────
    function setSettler(address settler, bool authorized) external onlyOwner {
        authorizedSettlers[settler] = authorized;
        emit SettlerSet(settler, authorized);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert TreasuryIsZero();
        emit TreasurySet(treasury, t);
        treasury = t;
    }

    function setReviewerPool(address r) external onlyOwner {
        if (r == address(0)) revert ReviewerPoolIsZero();
        emit ReviewerPoolSet(reviewerPool, r);
        reviewerPool = r;
    }

    function setRegistry(address r) external onlyOwner {
        emit RegistrySet(address(registry), r);
        registry = IBuildersRegistry(r);
    }

    function transferOwnership(address newOwner) external onlyOwner {
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

    /// Accept direct funding (e.g. a settler pre-funding the donut). Does not
    /// credit anyone — use settle() for that.
    receive() external payable {}
}
