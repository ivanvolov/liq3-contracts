// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice USDT-semantics mock: 6 decimals, transfer/transferFrom/approve return
///         NOTHING (not even false), and approve reverts when going nonzero->nonzero.
///         The system's main asset behaves like this on mainnet, so the test suite
///         must prove SafeERC20 handles it end to end.
contract MockUSDT {
    string public constant name = "Tether USD";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) external {
        _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "USDT: allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external {
        // Real USDT's anti-front-running guard: must approve to 0 first.
        require(value == 0 || allowance[msg.sender][spender] == 0, "USDT: approve from nonzero");
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "USDT: balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
