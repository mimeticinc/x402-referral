// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Minimal fee-on-transfer token: `transfer` (outbound) takes a 1% fee so
 *         the recipient receives less than requested; `transferFrom` (the Permit2
 *         pull) is untaxed. Used to prove the splitter's exact-amount balance
 *         checks revert instead of emitting amounts the recipients didn't receive.
 */
contract MockFeeERC20 is IERC20 {
    string public name = "Fee USDC";
    string public symbol = "fUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Untaxed — used by Permit2 to pull the full amount to the proxy.
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @dev Taxed 1% — recipient receives less than `amount`.
    function transfer(address to, uint256 amount) external override returns (bool) {
        uint256 fee = amount / 100;
        uint256 net = amount - fee;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += net;
        balanceOf[address(0xFEE)] += fee;
        emit Transfer(msg.sender, to, net);
        return true;
    }
}
