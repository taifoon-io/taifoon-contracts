// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TaifoonTransition} from "../../../lib/TaifoonTransition.sol";
import {TaifoonAttest} from "../../../lib/TaifoonAttest.sol";
import {ITaifoonProtocolVerifier} from "../interface.sol";
import {Deployments} from "../Deployments.sol";

/// @notice The ERC-20 surface the release needs.
interface IERC20Release {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title CrossChainRelease — a vendor on "chain B": pays a reseller its markup for a sale proven settled on chain A
/// @notice The sale settled on chain A (its `settled:ok` transition is a leaf of the superroot); this contract on
///         chain B holds an ERC-20 and, when chain B's verifier calls it for that proven transition, pays the
///         reseller. What binds the payment to the proof is an EIP-712 `Release` signed by the sale's buyer-side key
///         (Rome's SettleAuthorization pattern): any caller may relay it, the signature binds the destination chain,
///         the sale, the payee, the amount and a deadline, and the replay guard is the proven leaf itself.
contract CrossChainRelease {
    /// EIP-712 `Release(uint64 dstChainId,bytes32 orderKeyHash,address payee,uint256 amount,uint64 deadline)`.
    struct Release {
        uint64 dstChainId;
        bytes32 orderKeyHash;
        address payee;
        uint256 amount;
        uint64 deadline;
    }

    // literals (inline assembly reads only literal constants); test/sdk/Constants.t.sol pins each to its keccak256
    /// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    /// keccak256("Release(uint64 dstChainId,bytes32 orderKeyHash,address payee,uint256 amount,uint64 deadline)")
    bytes32 private constant RELEASE_TYPEHASH = 0x1e351c13c494486eeed5c0c13a53a5d0b1063f3ffb657a5943da3d4c11d009f3;
    bytes32 public constant SETTLED_OK = keccak256(abi.encodePacked("settled", ":", "ok"));
    /// keccak256("TaifoonCrossChainRelease")
    bytes32 private constant NAME_HASH = 0x60359a5387e971583c839868741b4833386c098b639d57bce24099dc8568e75d;
    /// keccak256("1")
    bytes32 private constant VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    /// Chain B's TaifoonProtocolVerifier: the only caller of `release`.
    address public immutable verifier;
    /// The token paid out.
    address public immutable token;
    /// The buyer-side key of the sales this vendor releases for.
    address public immutable authorizer;
    address public immutable owner;
    /// Proven leaf → paid once.
    mapping(bytes32 => bool) public released;

    event Released(bytes32 indexed leaf, bytes32 indexed orderKeyHash, address indexed payee, uint256 amount);

    error NotVerifier();
    error NoProvenLeaf();
    error LeafMismatch(bytes32 leaf, bytes32 currentLeaf);
    error NotSettledOk(bytes32 toState);
    error WrongSale(bytes32 proven, bytes32 authorized);
    error WrongChain(uint64 dstChainId);
    error Expired(uint64 deadline);
    error AlreadyReleased(bytes32 leaf);
    error BadSigner(address recovered);
    error NotOwner();
    error TransferFailed();

    constructor(address _verifier, address _token, address _authorizer, address _owner) {
        verifier = _verifier;
        token = _token;
        authorizer = _authorizer;
        owner = _owner;
    }

    /// @notice The digest the buyer-side key signs.
    function releaseDigest(Release calldata r) public view returns (bytes32 h) {
        uint256 dst = r.dstChainId;
        bytes32 sale = r.orderKeyHash;
        address payee = r.payee;
        uint256 amount = r.amount;
        uint256 deadline = r.deadline;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, DOMAIN_TYPEHASH)
            mstore(add(p, 32), NAME_HASH)
            mstore(add(p, 64), VERSION_HASH)
            mstore(add(p, 96), chainid())
            mstore(add(p, 128), address())
            let domain := keccak256(p, 160)
            mstore(p, RELEASE_TYPEHASH)
            mstore(add(p, 32), dst)
            mstore(add(p, 64), sale)
            mstore(add(p, 96), and(payee, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 128), amount)
            mstore(add(p, 160), deadline)
            let s := keccak256(p, 192)
            mstore(p, shl(240, 0x1901))
            mstore(add(p, 2), domain)
            mstore(add(p, 34), s)
            h := keccak256(p, 66)
        }
    }

    /// @notice Called by the verifier inside executeVerifiedTransition: `t` is the transition in view, a `settled:ok`
    ///         step of the coordination protocol; `r` is the signed release for that sale on this chain. Pays once.
    function release(TaifoonTransition.Transition calldata t, Release calldata r, bytes calldata signature) external {
        if (msg.sender != verifier) revert NotVerifier();
        bytes32 current = ITaifoonProtocolVerifier(verifier).currentLeaf();
        if (current == bytes32(0)) revert NoProvenLeaf();
        bytes32 leaf = TaifoonTransition.leafCalldata(t);
        if (leaf != current) revert LeafMismatch(leaf, current);
        if (t.protocolId != Deployments.COORD || t.toState != SETTLED_OK) revert NotSettledOk(t.toState);
        if (r.orderKeyHash != t.orderKeyHash) revert WrongSale(t.orderKeyHash, r.orderKeyHash);
        if (r.dstChainId != block.chainid) revert WrongChain(r.dstChainId);
        if (block.timestamp > r.deadline) revert Expired(r.deadline);
        if (released[leaf]) revert AlreadyReleased(leaf);
        address signer = TaifoonAttest.signerCalldata(releaseDigest(r), signature);
        if (signer == address(0) || signer != authorizer) revert BadSigner(signer);
        released[leaf] = true;
        if (!IERC20Release(token).transfer(r.payee, r.amount)) revert TransferFailed();
        emit Released(leaf, r.orderKeyHash, r.payee, r.amount);
    }

    /// @notice Owner: move tokens out (funding is a plain transfer in).
    function withdraw(address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        if (!IERC20Release(token).transfer(to, amount)) revert TransferFailed();
    }
}
