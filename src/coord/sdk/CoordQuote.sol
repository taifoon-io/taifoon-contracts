// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICoordQuote, ITaifoonPaymentChannel, ITaifoonProtocolVerifier, ITsulDonut} from "./interface.sol";

/// @title CoordQuote — the gas and value a coord-layer capability costs, before the caller signs
/// @notice One `quote` across the four capabilities a sale runs through: `open` (channel), `executeVerifiedTransition`
///         (verifier: prove + act), `distribute` (channel) and `settle` (donut). The gas figures are the ones measured
///         by the economy bench (test/bench/EconomyBench.t.sol, `forge test --gas-report`) and are state the owner
///         re-pins when a module changes; the value is what the capability must carry (only the donut carries any).
contract CoordQuote is ICoordQuote {
    address public owner;
    mapping(bytes4 => uint256) public gasOf;

    event GasSet(bytes4 indexed selector, uint256 gas);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error UnknownCapability(bytes4 selector);

    constructor(address _owner) {
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
        // the economy bench's measured maxima over 30 venue pairs (mode-1 plan of ≤ 4 legs, one-leaf history proof,
        // the first, storage-cold call of each): open 258,697 · act 195,179 · distribute 92,897 · donut 124,790
        _set(ITaifoonPaymentChannel.open.selector, 260_000);
        _set(ITaifoonProtocolVerifier.executeVerifiedTransition.selector, 200_000);
        _set(ITaifoonPaymentChannel.distribute.selector, 95_000);
        _set(ITsulDonut.settle.selector, 125_000);
    }

    /// @inheritdoc ICoordQuote
    function quote(bytes4 selector, bytes calldata args) external view returns (uint256 gas, uint256 value) {
        gas = gasOf[selector];
        if (gas == 0) revert UnknownCapability(selector);
        if (selector == ITsulDonut.settle.selector) {
            // the donut's args: (bountyId, contributor, callRevenue, fee) — the fee rides as value
            (,,, value) = abi.decode(args, (bytes32, address, uint256, uint256));
        }
    }

    /// @notice Owner: re-pin a capability's measured gas (zero removes it).
    function setGas(bytes4 selector, uint256 gas) external {
        if (msg.sender != owner) revert NotOwner();
        _set(selector, gas);
    }

    /// @notice Owner: hand the seat over (one step: this contract holds no funds).
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _set(bytes4 selector, uint256 gas) internal {
        gasOf[selector] = gas;
        emit GasSet(selector, gas);
    }
}
