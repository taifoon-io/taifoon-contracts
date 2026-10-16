// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// A USDC-like token for the SDK tests and the economy bench (6 decimals, returns true).
contract MockUSDC {
    string public constant name = "USD Coin (mock)";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Stands in for a verifier mid-execution: `currentLeaf()` is whatever the test set.
contract LeafStub {
    bytes32 public currentLeaf;

    function set(bytes32 leaf) external {
        currentLeaf = leaf;
    }
}
