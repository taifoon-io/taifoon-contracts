// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TaifoonAttest} from "../lib/TaifoonAttest.sol";
import {TaifoonTransition} from "../lib/TaifoonTransition.sol";

/// @notice The minimal ERC-20 surface a channel needs (USDC-like: returns a boolean or nothing).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice What the channel reads from TaifoonProtocolVerifier while it is being called as a vendor.
interface IProvenLeafSource {
    function currentLeaf() external view returns (bytes32);
}

/// @title TaifoonPaymentChannel — payer→payee ERC-20 escrow channels settled by cumulative vouchers
/// @notice The EVM port of the Solana Foundation payment-channels program (Moonsong) for the Taifoon coordination
///         layer: the layer is the payee of record, its vault is the `treasury`. One contract holds every channel;
///         a channel is one sale (`orderKeyHash` = keccak of the coordination sale key) funded by the payer, paid
///         out by a distribution plan committed by hash at `open` and revealed at `distribute`.
///
///         State machine (the reference's, docs/001-payment-channel-state-machine.md):
///           NONE ─open(payer)→ OPEN ─settle/topUp/distribute(partial)→ OPEN
///           OPEN ─requestClose(payer)→ CLOSING ─seal(anyone, after grace)→ SEALED
///           OPEN|CLOSING ─settleAndSeal(payee, optional voucher)→ SEALED
///           OPEN|CLOSING ─sealProven(anyone, sale proven `settled:ok`)→ SEALED        (the layer's addition)
///           SEALED ─withdrawPayer(payer, once)→ SEALED ─distribute(anyone, final)→ storage deleted (Closed)
///
///         Two distribution modes: 0 = bps (floor-delta telescoping, the payee takes the remainder, partial
///         distributes allowed), 1 = absolute (Σ amounts == settled at the final distribute, no partials: the layer's
///         one payment scheme where our fee + venue fees + seller share + reseller markup must sum exactly).
contract TaifoonPaymentChannel {
    enum Status {
        NONE,
        OPEN,
        CLOSING,
        SEALED
    }

    /// The channel as `channelOf` returns it (the ABI view; unchanged since the port).
    struct Channel {
        address payer;
        Status status;
        uint32 gracePeriod; // seconds after requestClose before anyone may seal
        uint64 closureStartedAt; // live only in CLOSING
        address payee;
        bool payerWithdrawn; // the one-shot refund was taken in SEALED
        address authorizedSigner; // the key that signs vouchers
        address token;
        uint256 salt;
        uint256 deposit; // escrow ceiling for `settled`; raised by topUp in OPEN
        uint256 settled; // cumulative payer-authorized amount
        uint256 payoutWatermark; // settled amount already accounted by distribute (≤ settled)
        uint256 paid; // tokens that have left this channel's escrow (payouts, redirects, refund)
        bytes32 distributionHash;
        bytes32 orderKeyHash; // the coordination sale this channel pays for (may be zero)
    }

    /// The channel as it is STORED: 9 slots instead of 11 (the 2026-10-14 pass). Slot 0 packs payer, status, grace,
    /// the one-shot refund flag and the closure time (uint48: seconds fit until the year 8,921,556); the four
    /// amounts are uint128 pairs — 2^128 − 1 units is 3.4e32 USDC (6 decimals) or 3.4e20 of an 18-decimal token, above
    /// any ERC-20's supply, and `open` / `topUp` refuse a deposit above it (AmountTooLarge) so the bound is explicit.
    struct ChannelS {
        address payer; // 20 ┐
        Status status; // 1  │ slot 0
        uint32 gracePeriod; // 4  │
        bool payerWithdrawn; // 1  │
        uint48 closureStartedAt; // 6  ┘
        address payee; // slot 1
        address authorizedSigner; // slot 2
        address token; // slot 3
        uint256 salt; // slot 4
        uint128 deposit; // slot 5 ┐
        uint128 settled; //        ┘
        uint128 payoutWatermark; // slot 6 ┐
        uint128 paid; //                  ┘
        bytes32 distributionHash; // slot 7
        bytes32 orderKeyHash; // slot 8
    }

    /// EIP-712 `Voucher(bytes32 channelId,uint256 cumulative,uint64 expiresAt)`, signed by the authorized signer.
    struct Voucher {
        bytes32 channelId;
        uint256 cumulative;
        uint64 expiresAt;
    }

    /// The distribution plan: mode 0 amounts are bps (≤ 10000 each, Σ ≤ 10000), mode 1 amounts are token units.
    struct Distribution {
        uint8 mode;
        address[] recipients;
        uint256[] amounts;
    }

    // ── constants ──────────────────────────────────────────────────────────────────────────────────────────────

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_RECIPIENTS = 32;
    uint32 public constant MIN_GRACE = 15 minutes;
    uint8 public constant MODE_BPS = 0;
    uint8 public constant MODE_ABSOLUTE = 1;
    /// TaifoonCoordLambda.stateOf("settled", "ok"): the state word that releases the escrow without a voucher.
    bytes32 public constant SETTLED_OK = keccak256(abi.encodePacked("settled", ":", "ok"));
    /// The protocol whose proven transitions this contract acts on.
    bytes32 public constant COORD = keccak256("taifoon_coord");
    // literals (inline assembly reads only literal constants); test/sdk/Constants.t.sol pins each to its keccak256
    /// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    /// keccak256("Voucher(bytes32 channelId,uint256 cumulative,uint64 expiresAt)")
    bytes32 private constant VOUCHER_TYPEHASH = 0xde032b55f23cfa976e0cf58f44a51b0900e10d45617be6db39758f8e8f09d24e;
    /// keccak256("TaifoonPaymentChannel")
    bytes32 private constant NAME_HASH = 0xea03d49bcdc594f44f9fc6e398313cef63bfc3e3fcbd53afc04e73afa0e6c997;
    /// keccak256("1")
    bytes32 private constant VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    // ── state ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// The vault: receives rounding dust at the final distribute and every payout a recipient cannot take.
    address public immutable treasury;
    /// TaifoonProtocolVerifier, the only caller of onProven (zero = the proven gate is off).
    address public immutable verifier;
    address public owner;
    address public pendingOwner;
    mapping(bytes32 => ChannelS) internal channels;
    /// channelId → the sale's last proven state (set by the verifier through onProven).
    mapping(bytes32 => bytes32) public provenState;
    /// token → tokens held for live channels; anything above it is surplus the owner may sweep to the treasury.
    mapping(address => uint256) public escrowed;
    uint256 private _lock;

    // ── events (every leg of the fee trace) ────────────────────────────────────────────────────────────────────

    event Opened(
        bytes32 indexed channelId,
        address indexed payer,
        address indexed payee,
        address token,
        address authorizedSigner,
        uint256 salt,
        uint256 deposit,
        uint32 gracePeriod,
        bytes32 distributionHash,
        bytes32 orderKeyHash
    );
    event Settled(bytes32 indexed channelId, uint256 cumulative, address signer);
    event ToppedUp(bytes32 indexed channelId, uint256 amount, uint256 deposit);
    event CloseRequested(bytes32 indexed channelId, uint64 deadline);
    event Sealed(bytes32 indexed channelId, uint256 settled);
    event PayerWithdrawn(bytes32 indexed channelId, address indexed payer, uint256 amount);
    event Distributed(bytes32 indexed channelId, address indexed recipient, uint256 amount, uint8 mode);
    event PayoutRedirected(bytes32 indexed channelId, address indexed recipient, uint256 amount);
    event DustSwept(bytes32 indexed channelId, uint256 amount);
    event Proven(bytes32 indexed channelId, bytes32 indexed leaf, bytes32 toState);
    event Closed(bytes32 indexed channelId);
    event SurplusSwept(address indexed token, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ── errors ─────────────────────────────────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotPendingOwner();
    error Reentered();
    error ZeroAddress();
    error NotAContract(address token);
    error PayerIsPayee();
    error ZeroAmount();
    error GraceTooShort(uint32 gracePeriod, uint32 min);
    error ChannelExists(bytes32 channelId);
    error WrongStatus(bytes32 channelId, Status status);
    error NotPayer();
    error NotPayee();
    error BadDistribution();
    error DuplicateRecipient(address recipient);
    error DistributionMismatch();
    error PartialNotAllowed();
    error NothingToDistribute();
    error AbsoluteSumMismatch(uint256 sum, uint256 settled);
    error VoucherChannelMismatch();
    error VoucherExpired(uint64 expiresAt);
    error VoucherOverDeposit(uint256 cumulative, uint256 deposit);
    error VoucherNotMonotonic(uint256 cumulative, uint256 settled);
    error VoucherSigner(address recovered);
    error GraceNotElapsed(uint64 deadline);
    error GraceElapsed(uint64 deadline);
    error AlreadyWithdrawn();
    error FeeOnTransferToken(uint256 expected, uint256 received);
    error TransferFailed(address token, address to, uint256 amount);
    error NotVerifier();
    error NoProvenLeaf();
    error LeafMismatch(bytes32 leaf, bytes32 currentLeaf);
    error WrongSale(bytes32 orderKeyHash, bytes32 proven);
    error NotProvenSettled(bytes32 channelId, bytes32 provenState);
    error NoSurplus();
    error AmountTooLarge(uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// 1 = free, 2 = entered: the slot never returns to zero, so a guarded call costs a warm non-zero write and
    /// its reset, not a zero → non-zero SSTORE (set once in the constructor).
    modifier nonReentrant() {
        if (_lock == 2) revert Reentered();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address _owner, address _treasury, address _verifier) {
        if (_owner == address(0) || _treasury == address(0)) revert ZeroAddress();
        owner = _owner;
        treasury = _treasury;
        verifier = _verifier;
        _lock = 1;
        emit OwnershipTransferred(address(0), _owner);
    }

    // ── views ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The channel's whole record (status NONE once it is closed: the storage is deleted).
    function channelOf(bytes32 channelId) external view returns (Channel memory) {
        ChannelS storage ch = channels[channelId];
        Channel memory c;
        c.payer = ch.payer;
        c.status = ch.status;
        c.gracePeriod = ch.gracePeriod;
        c.closureStartedAt = ch.closureStartedAt;
        c.payee = ch.payee;
        c.payerWithdrawn = ch.payerWithdrawn;
        c.authorizedSigner = ch.authorizedSigner;
        c.token = ch.token;
        c.salt = ch.salt;
        c.deposit = ch.deposit;
        c.settled = ch.settled;
        c.payoutWatermark = ch.payoutWatermark;
        c.paid = ch.paid;
        c.distributionHash = ch.distributionHash;
        c.orderKeyHash = ch.orderKeyHash;
        return c;
    }

    /// @notice The channel id of a tuple opened at `blockNumber` (the reference's open_slot: the incarnation binding).
    function channelIdOf(
        address payer,
        address payee,
        address token,
        address authorizedSigner,
        uint256 salt,
        uint256 blockNumber
    ) public pure returns (bytes32 h) {
        // keccak256(abi.encode(the six words)), over scratch memory
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, and(payer, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 32), and(payee, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 64), and(token, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 96), and(authorizedSigner, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 128), salt)
            mstore(add(p, 160), blockNumber)
            h := keccak256(p, 192)
        }
    }

    /// @notice The hash a distribution plan is committed under at `open` and checked against at `distribute`.
    function distributionHashOf(Distribution calldata d) external pure returns (bytes32) {
        return _distributionHash(d);
    }

    /// @notice The EIP-712 digest the authorized signer signs for a voucher (domain: name, version, chainId, this).
    function voucherDigest(Voucher calldata v) public view returns (bytes32 h) {
        // the domain (name, version, chainId, this) and the struct hash, both over scratch memory; `0x1901 ‖ domain ‖ struct`
        bytes32 channelId = v.channelId;
        uint256 cumulative = v.cumulative;
        uint256 expiresAt = v.expiresAt;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, DOMAIN_TYPEHASH)
            mstore(add(p, 32), NAME_HASH)
            mstore(add(p, 64), VERSION_HASH)
            mstore(add(p, 96), chainid())
            mstore(add(p, 128), address())
            let domain := keccak256(p, 160)
            mstore(p, VOUCHER_TYPEHASH)
            mstore(add(p, 32), channelId)
            mstore(add(p, 64), cumulative)
            mstore(add(p, 96), expiresAt)
            let s := keccak256(p, 128)
            mstore(p, shl(240, 0x1901))
            mstore(add(p, 2), domain)
            mstore(add(p, 34), s)
            h := keccak256(p, 66)
        }
    }

    // ── the state machine ──────────────────────────────────────────────────────────────────────────────────────

    /// @notice Open a channel: the caller is the payer and deposits `deposit` of `token`; the distribution plan is
    ///         validated and committed by hash. Fee-on-transfer tokens are refused (the escrow must receive exactly
    ///         `deposit`). `gracePeriod` is the wait between requestClose and a permissionless seal (≥ 15 minutes).
    function open(
        address payee,
        address token,
        address authorizedSigner,
        uint256 salt,
        uint256 deposit,
        uint32 gracePeriod,
        bytes32 orderKeyHash,
        Distribution calldata d
    ) external nonReentrant returns (bytes32 channelId) {
        if (payee == address(0) || authorizedSigner == address(0)) revert ZeroAddress();
        if (payee == msg.sender) revert PayerIsPayee();
        if (token.code.length == 0) revert NotAContract(token);
        if (deposit == 0) revert ZeroAmount();
        if (gracePeriod < MIN_GRACE) revert GraceTooShort(gracePeriod, MIN_GRACE);
        if (deposit > type(uint128).max) revert AmountTooLarge(deposit);
        channelId = channelIdOf(msg.sender, payee, token, authorizedSigner, salt, block.number);
        ChannelS storage ch = channels[channelId];
        if (ch.status != Status.NONE) revert ChannelExists(channelId);
        bytes32 distributionHash = _validateDistribution(d);

        // one write per slot (a memory struct copied into storage)
        channels[channelId] = ChannelS({
            payer: msg.sender,
            status: Status.OPEN,
            gracePeriod: gracePeriod,
            payerWithdrawn: false,
            closureStartedAt: 0,
            payee: payee,
            authorizedSigner: authorizedSigner,
            token: token,
            salt: salt,
            deposit: uint128(deposit),
            settled: 0,
            payoutWatermark: 0,
            paid: 0,
            distributionHash: distributionHash,
            orderKeyHash: orderKeyHash
        });
        escrowed[token] += deposit;
        _pull(token, msg.sender, deposit);
        emit Opened(channelId, msg.sender, payee, token, authorizedSigner, salt, deposit, gracePeriod, distributionHash, orderKeyHash);
    }

    /// @notice Permissionless: advance `settled` with a voucher of the authorized signer (OPEN only). A voucher is
    ///         never stored: `settled < cumulative ≤ deposit` makes a replay impossible.
    function settle(Voucher calldata v, bytes calldata signature) external {
        ChannelS storage ch = channels[v.channelId];
        if (ch.status != Status.OPEN) revert WrongStatus(v.channelId, ch.status);
        _applyVoucher(ch, v, signature);
    }

    /// @notice Payer: add `amount` to the escrow and raise the deposit ceiling (OPEN only).
    function topUp(bytes32 channelId, uint256 amount) external nonReentrant {
        ChannelS storage ch = channels[channelId];
        if (ch.status != Status.OPEN) revert WrongStatus(channelId, ch.status);
        if (msg.sender != ch.payer) revert NotPayer();
        if (amount == 0) revert ZeroAmount();
        uint256 deposit = ch.deposit + amount;
        if (deposit > type(uint128).max) revert AmountTooLarge(deposit);
        ch.deposit = uint128(deposit);
        address token = ch.token;
        escrowed[token] += amount;
        _pull(token, msg.sender, amount);
        emit ToppedUp(channelId, amount, deposit);
    }

    /// @notice Payer: start the grace period (OPEN → CLOSING). The payee may still settleAndSeal until the deadline.
    function requestClose(bytes32 channelId) external {
        ChannelS storage ch = channels[channelId];
        if (ch.status != Status.OPEN) revert WrongStatus(channelId, ch.status);
        if (msg.sender != ch.payer) revert NotPayer();
        ch.status = Status.CLOSING;
        ch.closureStartedAt = uint48(block.timestamp);
        emit CloseRequested(channelId, uint64(block.timestamp) + ch.gracePeriod);
    }

    /// @notice Permissionless: seal a CLOSING channel once the grace period has elapsed (the watermark freezes).
    function seal(bytes32 channelId) external {
        ChannelS storage ch = channels[channelId];
        if (ch.status != Status.CLOSING) revert WrongStatus(channelId, ch.status);
        uint64 deadline = uint64(ch.closureStartedAt) + ch.gracePeriod;
        if (block.timestamp < deadline) revert GraceNotElapsed(deadline);
        _seal(channelId, ch);
    }

    /// @notice Payee: cooperative close from OPEN, or from CLOSING before the deadline. An empty `signature` seals
    ///         the current watermark; otherwise the voucher is applied first under the rules of `settle`.
    function settleAndSeal(bytes32 channelId, Voucher calldata v, bytes calldata signature) external {
        ChannelS storage ch = channels[channelId];
        Status st = ch.status;
        if (st == Status.CLOSING) {
            uint64 deadline = uint64(ch.closureStartedAt) + ch.gracePeriod;
            if (block.timestamp >= deadline) revert GraceElapsed(deadline);
        } else if (st != Status.OPEN) {
            revert WrongStatus(channelId, st);
        }
        if (msg.sender != ch.payee) revert NotPayee();
        if (signature.length != 0) {
            if (v.channelId != channelId) revert VoucherChannelMismatch();
            _applyVoucher(ch, v, signature);
        }
        _seal(channelId, ch);
    }

    /// @notice Payer, once, in SEALED: take back `deposit − settled` without waiting for the final distribute.
    function withdrawPayer(bytes32 channelId) external nonReentrant {
        ChannelS storage ch = channels[channelId];
        if (ch.status != Status.SEALED) revert WrongStatus(channelId, ch.status);
        if (msg.sender != ch.payer) revert NotPayer();
        if (ch.payerWithdrawn) revert AlreadyWithdrawn();
        ch.payerWithdrawn = true;
        uint256 refund;
        unchecked {
            refund = uint256(ch.deposit) - ch.settled; // settled ≤ deposit: every voucher is checked against the deposit, sealProven sets settled = deposit
            ch.paid += uint128(refund); // paid + refund ≤ deposit (the refund is the part never paid)
        }
        address token = ch.token;
        escrowed[token] -= refund;
        if (refund != 0) _safeTransfer(token, msg.sender, refund);
        emit PayerWithdrawn(channelId, msg.sender, refund);
    }

    /// @notice Permissionless: pay the plan. In OPEN (mode 0 only) each recipient gets the floor delta
    ///         `floor(settled·bps/10000) − floor(watermark·bps/10000)`, the payee the delta of the remainder, and the
    ///         watermark advances to `settled`, so partial distributes telescope to exactly the final amounts. In
    ///         SEALED the same final deltas are paid (mode 1: the absolute amounts, which must sum to `settled`),
    ///         the payer is refunded `deposit − settled` unless already withdrawn, the rounding dust goes to the
    ///         treasury, and the channel's storage is deleted. A recipient whose transfer fails is paid to the
    ///         treasury instead (PayoutRedirected) and the watermark still advances.
    function distribute(bytes32 channelId, Distribution calldata d) external nonReentrant {
        ChannelS storage ch = channels[channelId];
        Status st = ch.status;
        if (st != Status.OPEN && st != Status.SEALED) revert WrongStatus(channelId, st);
        if (_distributionHash(d) != ch.distributionHash) revert DistributionMismatch();
        if (st == Status.OPEN) _distributePartial(channelId, ch, d);
        else _distributeFinal(channelId, ch, d);
    }

    // ── the proven gate (vendor of TaifoonProtocolVerifier) ───────────────────────────────────────────────────

    /// @notice Called by the verifier inside executeVerifiedTransition: `t` must be the transition in view
    ///         (`currentLeaf()`), of the coordination protocol, for this channel's sale. Records the sale's state.
    function onProven(bytes32 channelId, TaifoonTransition.Transition calldata t) external {
        if (msg.sender != verifier || verifier == address(0)) revert NotVerifier();
        bytes32 current = IProvenLeafSource(verifier).currentLeaf();
        if (current == bytes32(0)) revert NoProvenLeaf();
        bytes32 leaf = TaifoonTransition.leafCalldata(t);
        if (leaf != current) revert LeafMismatch(leaf, current);
        ChannelS storage ch = channels[channelId];
        if (ch.status == Status.NONE) revert WrongStatus(channelId, ch.status);
        bytes32 sale = ch.orderKeyHash;
        if (t.protocolId != COORD || sale == bytes32(0) || t.orderKeyHash != sale) revert WrongSale(sale, t.orderKeyHash);
        provenState[channelId] = t.toState;
        emit Proven(channelId, leaf, t.toState);
    }

    /// @notice Permissionless: a sale proven `settled:ok` releases the escrow without the payer's voucher — the
    ///         whole deposit becomes `settled` (a channel is one sale; the proof carries no amount the chain can
    ///         read) and the channel seals. What the Solana program lacks: an evaluated release.
    function sealProven(bytes32 channelId) external {
        ChannelS storage ch = channels[channelId];
        Status st = ch.status;
        if (st != Status.OPEN && st != Status.CLOSING) revert WrongStatus(channelId, st);
        bytes32 state = provenState[channelId];
        if (state != SETTLED_OK) revert NotProvenSettled(channelId, state);
        uint128 deposit = ch.deposit;
        ch.settled = deposit;
        emit Settled(channelId, deposit, verifier);
        _seal(channelId, ch);
    }

    // ── admin ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Owner: move tokens the contract holds above every live channel's escrow (direct sends) to the
    ///         treasury — the reference's surplus sweep, which there happens per escrow account at close.
    function sweepSurplus(address token) external onlyOwner nonReentrant {
        uint256 surplus = IERC20(token).balanceOf(address(this)) - escrowed[token];
        if (surplus == 0) revert NoSurplus();
        _safeTransfer(token, treasury, surplus);
        emit SurplusSwept(token, surplus);
    }

    /// @notice Two-step ownership, as in TaifoonProtocolVerifier.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice The pending owner takes the seat.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ── internals ──────────────────────────────────────────────────────────────────────────────────────────────

    function _applyVoucher(ChannelS storage ch, Voucher calldata v, bytes calldata signature) internal {
        if (block.timestamp > v.expiresAt) revert VoucherExpired(v.expiresAt);
        uint256 deposit = ch.deposit; // slot 5, read once (deposit ‖ settled)
        uint256 settled = ch.settled;
        if (v.cumulative > deposit) revert VoucherOverDeposit(v.cumulative, deposit);
        if (v.cumulative <= settled) revert VoucherNotMonotonic(v.cumulative, settled);
        address signer = TaifoonAttest.signerCalldata(voucherDigest(v), signature);
        if (signer == address(0) || signer != ch.authorizedSigner) revert VoucherSigner(signer);
        ch.settled = uint128(v.cumulative); // ≤ deposit ≤ 2^128 − 1
        emit Settled(v.channelId, v.cumulative, signer);
    }

    function _seal(bytes32 channelId, ChannelS storage ch) internal {
        ch.status = Status.SEALED;
        ch.closureStartedAt = 0;
        emit Sealed(channelId, ch.settled);
    }

    function _distributePartial(bytes32 channelId, ChannelS storage ch, Distribution calldata d) internal {
        if (d.mode != MODE_BPS) revert PartialNotAllowed();
        uint256 settled = ch.settled;
        uint256 watermark = ch.payoutWatermark; // slot 6 (watermark ‖ paid)
        if (settled == watermark) revert NothingToDistribute();
        (uint256[] memory legs, uint256 total) = _bpsLegs(d, settled, watermark);
        ch.payoutWatermark = uint128(settled);
        ch.paid += uint128(total); // paid ≤ deposit: the legs are a share of settled ≤ deposit
        address token = ch.token;
        escrowed[token] -= total;
        _payLegs(channelId, token, ch.payee, d, legs);
    }

    function _distributeFinal(bytes32 channelId, ChannelS storage ch, Distribution calldata d) internal {
        uint256 settled = ch.settled;
        uint256[] memory legs;
        uint256 total;
        if (d.mode == MODE_BPS) {
            (legs, total) = _bpsLegs(d, settled, ch.payoutWatermark);
        } else {
            uint256 n = d.amounts.length;
            legs = new uint256[](n + 1);
            for (uint256 i = 0; i < n;) {
                legs[i] = d.amounts[i];
                total += d.amounts[i]; // checked: absolute units, unbounded
                unchecked { ++i; } // n ≤ 32
            }
            if (total != settled) revert AbsoluteSumMismatch(total, settled);
        }
        uint256 deposit = ch.deposit;
        uint256 refund;
        uint256 balance;
        unchecked {
            refund = ch.payerWithdrawn ? 0 : deposit - settled; // settled ≤ deposit (see withdrawPayer)
            balance = deposit - ch.paid; // paid ≤ deposit: only legs of settled and the one refund ever leave
        }
        uint256 dust = balance - total - refund; // checked on purpose: the one place the plan meets the escrow
        address token = ch.token;
        address payee = ch.payee;
        address payer = ch.payer;
        escrowed[token] -= balance;
        delete channels[channelId];
        delete provenState[channelId];

        _payLegs(channelId, token, payee, d, legs);
        if (refund != 0 && _send(channelId, token, payer, refund)) emit PayerWithdrawn(channelId, payer, refund);
        if (dust != 0) {
            _safeTransfer(token, treasury, dust);
            emit DustSwept(channelId, dust);
        }
        emit Closed(channelId);
    }

    /// The floor deltas of every recipient and, last, of the payee's remainder, between `watermark` and `settled`.
    function _bpsLegs(Distribution calldata d, uint256 settled, uint256 watermark)
        internal
        pure
        returns (uint256[] memory legs, uint256 total)
    {
        uint256 n = d.amounts.length;
        legs = new uint256[](n + 1);
        uint256 used;
        unchecked {
            // the plan was validated at open: n ≤ 32, Σ bps ≤ 10,000; every delta ≤ settled − watermark ≤ 2^128
            for (uint256 i = 0; i < n; ++i) {
                uint256 bps = d.amounts[i];
                used += bps;
                legs[i] = _bpsDelta(settled, watermark, bps);
                total += legs[i];
            }
            legs[n] = _bpsDelta(settled, watermark, BPS - used);
            total += legs[n];
        }
    }

    /// `floor(settled·bps/10000) − floor(watermark·bps/10000)` (channel.rs SettlementWatermarks::delta_for_bps).
    function _bpsDelta(uint256 settled, uint256 watermark, uint256 bps) internal pure returns (uint256) {
        unchecked {
            // settled, watermark < 2^128 and bps ≤ 10,000: no product overflows; watermark ≤ settled: no underflow
            return (settled * bps) / BPS - (watermark * bps) / BPS;
        }
    }

    function _payLegs(bytes32 channelId, address token, address payee, Distribution calldata d, uint256[] memory legs)
        internal
    {
        uint256 n = d.recipients.length;
        for (uint256 i = 0; i < n;) {
            if (_send(channelId, token, d.recipients[i], legs[i])) emit Distributed(channelId, d.recipients[i], legs[i], d.mode);
            unchecked { ++i; } // n ≤ 32
        }
        if (_send(channelId, token, payee, legs[n])) emit Distributed(channelId, payee, legs[n], d.mode);
    }

    /// Pay one leg; a failed transfer is redirected to the treasury (the recipient forfeits it). False when nothing
    /// reached `to` (zero amount or redirected).
    function _send(bytes32 channelId, address token, address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return false;
        if (_tryTransfer(token, to, amount)) return true;
        _safeTransfer(token, treasury, amount);
        emit PayoutRedirected(channelId, to, amount);
        return false;
    }

    function _validateDistribution(Distribution calldata d) internal view returns (bytes32) {
        uint256 n = d.recipients.length;
        if (n != d.amounts.length || n > MAX_RECIPIENTS || d.mode > MODE_ABSOLUTE) revert BadDistribution();
        uint256 sum;
        for (uint256 i = 0; i < n;) {
            address r = d.recipients[i];
            uint256 a = d.amounts[i];
            if (r == address(0) || r == address(this) || a == 0) revert BadDistribution();
            for (uint256 j = 0; j < i;) {
                if (d.recipients[j] == r) revert DuplicateRecipient(r);
                unchecked { ++j; }
            }
            sum += a; // checked: mode 1 amounts are unbounded units
            unchecked { ++i; } // n ≤ 32
        }
        if (d.mode == MODE_BPS && sum > BPS) revert BadDistribution();
        return _distributionHash(d);
    }

    function _distributionHash(Distribution calldata d) internal pure returns (bytes32) {
        return keccak256(abi.encode(d.mode, d.recipients, d.amounts));
    }

    /// Pull `amount` from `from`, measured: the escrow must receive exactly `amount`.
    function _pull(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!_okReturn(ok, ret)) revert TransferFailed(token, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert FeeOnTransferToken(amount, received);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (!_tryTransfer(token, to, amount)) revert TransferFailed(token, to, amount);
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return _okReturn(ok, ret);
    }

    /// An ERC-20 transfer succeeded when the call did not revert and returned nothing or `true`.
    function _okReturn(bool ok, bytes memory ret) internal pure returns (bool) {
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }
}
