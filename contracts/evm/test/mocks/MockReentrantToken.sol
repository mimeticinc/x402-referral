// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Token that re-enters a target on outbound `transfer` (ERC-777-style
 *         callback). Used to prove `settle`'s `nonReentrant` guard blocks
 *         reentrancy during the split's outbound transfers. The armed re-entry
 *         MUST fail (return false) or the mock reverts loudly.
 */
contract MockReentrantToken is IERC20 {
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    address public target;
    bytes public attackCalldata;
    bool public armed;

    function arm(address _target, bytes calldata cd) external {
        target = _target;
        attackCalldata = cd;
        armed = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Untaxed standard pull (Permit2 path); does not re-enter.
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @dev Outbound transfer attempts to re-enter `target` once; re-entry must be blocked.
    function transfer(address to, uint256 amount) external override returns (bool) {
        if (armed && msg.sender == target) {
            armed = false;
            (bool ok,) = target.call(attackCalldata);
            require(!ok, "reentrancy was NOT blocked");
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}
