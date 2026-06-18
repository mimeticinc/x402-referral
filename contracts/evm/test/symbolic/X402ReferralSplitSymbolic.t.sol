// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {X402ReferralSplitProxy} from "../../src/X402ReferralSplitProxy.sol";
import {ISignatureTransfer} from "../../src/interfaces/ISignatureTransfer.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title X402ReferralSplitSymbolic
 * @notice Formal (symbolic) proofs for the referral splitter, run with Halmos.
 *
 * @dev Functions prefixed `check_` are explored symbolically by Halmos:
 *      arguments are symbolic, so a passing run is a proof over ALL inputs in the
 *      assumed domain (not just sampled ones, as with foundry fuzzing).
 *
 *      Run:  halmos --function check_ --contract X402ReferralSplitSymbolic
 *      (requires `forge build` to have produced artifacts first)
 */
contract X402ReferralSplitSymbolic is Test {
    X402ReferralSplitProxy proxy;
    MockPermit2 mockPermit2;
    MockERC20 token;

    address payer;
    address merchant;
    address referrer;

    function setUp() public {
        payer = address(0xA11CE);
        merchant = address(0xB0B);
        referrer = address(0xCAFE);

        mockPermit2 = new MockPermit2();
        mockPermit2.setShouldActuallyTransfer(true);
        proxy = new X402ReferralSplitProxy(address(mockPermit2));
        token = new MockERC20("USDC", "USDC", 6);

        vm.prank(payer);
        token.approve(address(mockPermit2), type(uint256).max);
    }

    /// @notice PROOF: a successful settle splits funds exactly and retains nothing,
    ///         for every (amount, referrerAmount) in the valid domain.
    function check_settle_conservesAndSplitsExactly(uint256 amount, uint256 referrerAmount) public {
        // Valid input domain (the contract's accepted preconditions).
        vm.assume(amount > 0 && amount <= 1e30);
        vm.assume(referrerAmount > 0 && referrerAmount <= amount);
        // Distinct, nonzero recipients so balances are unambiguous.
        vm.assume(merchant != referrer);

        token.mint(payer, amount);
        uint256 supply = token.balanceOf(payer);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: 0,
            deadline: block.timestamp + 1
        });
        X402ReferralSplitProxy.Witness memory witness = X402ReferralSplitProxy.Witness({
            merchant: merchant,
            referrer: referrer,
            referrerAmount: referrerAmount,
            validAfter: 0,
            attributionId: bytes32(0)
        });

        proxy.settle(permit, payer, witness, hex"00");

        // Exact split.
        assertEq(token.balanceOf(referrer), referrerAmount);
        assertEq(token.balanceOf(merchant), amount - referrerAmount);
        // No retention, no creation/destruction.
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(
            token.balanceOf(payer) + token.balanceOf(merchant) + token.balanceOf(referrer), supply
        );
    }

    /// @notice PROOF: settle always reverts when referrerAmount is out of bounds.
    function check_settle_revertsOnInvalidReferrerAmount(uint256 amount, uint256 referrerAmount) public {
        vm.assume(amount > 0 && amount <= 1e30);
        vm.assume(referrerAmount == 0 || referrerAmount > amount);

        token.mint(payer, amount);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: 0,
            deadline: block.timestamp + 1
        });
        X402ReferralSplitProxy.Witness memory witness = X402ReferralSplitProxy.Witness({
            merchant: merchant,
            referrer: referrer,
            referrerAmount: referrerAmount,
            validAfter: 0,
            attributionId: bytes32(0)
        });

        try proxy.settle(permit, payer, witness, hex"00") {
            assert(false); // must not succeed
        } catch {}
    }
}
