// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {X402ReferralSplitProxy} from "../src/X402ReferralSplitProxy.sol";
import {x402BasePermit2Proxy} from "../src/x402BasePermit2Proxy.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeERC20} from "./mocks/MockFeeERC20.sol";
import {MockReentrantToken} from "./mocks/MockReentrantToken.sol";

contract X402ReferralSplitProxyTest is Test {
    X402ReferralSplitProxy public proxy;
    MockPermit2 public mockPermit2;
    MockERC20 public token;

    address public payer;
    address public merchant;
    address public referrer;

    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant TRANSFER_AMOUNT = 100e6; // 100 USDC
    uint256 constant SPLIT_BPS = 2000; // 20%
    uint256 constant REFERRER_AMOUNT = (TRANSFER_AMOUNT * SPLIT_BPS) / 10_000; // 20 USDC
    bytes32 constant ATTRIBUTION = keccak256("att_test");

    event ReferralSettled(
        bytes32 indexed attributionId,
        address indexed merchant,
        address indexed referrer,
        address token,
        uint256 merchantAmount,
        uint256 referrerAmount,
        address payer
    );

    function setUp() public {
        vm.warp(1_000_000);

        payer = makeAddr("payer");
        merchant = makeAddr("merchant");
        referrer = makeAddr("referrer");

        mockPermit2 = new MockPermit2();
        mockPermit2.setShouldActuallyTransfer(true);
        proxy = new X402ReferralSplitProxy(address(mockPermit2));
        token = new MockERC20("USDC", "USDC", 6);

        token.mint(payer, MINT_AMOUNT);
        vm.prank(payer);
        token.approve(address(mockPermit2), type(uint256).max);
    }

    function _permit(uint256 amount, uint256 nonce)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: nonce,
            deadline: block.timestamp + 3600
        });
    }

    function _witness(address m, address r, uint256 referrerAmount, uint256 validAfter)
        internal
        pure
        returns (X402ReferralSplitProxy.Witness memory)
    {
        return X402ReferralSplitProxy.Witness({
            merchant: m,
            referrer: r,
            referrerAmount: referrerAmount,
            validAfter: validAfter,
            attributionId: ATTRIBUTION
        });
    }

    function _sig() internal pure returns (bytes memory) {
        return hex"00";
    }

    function test_settle_splitsFundsAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit ReferralSettled(
            ATTRIBUTION, merchant, referrer, address(token), TRANSFER_AMOUNT - REFERRER_AMOUNT, REFERRER_AMOUNT, payer
        );

        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0), payer, _witness(merchant, referrer, REFERRER_AMOUNT, block.timestamp - 1), _sig()
        );

        assertEq(token.balanceOf(referrer), REFERRER_AMOUNT, "referrer gets commission");
        assertEq(token.balanceOf(merchant), TRANSFER_AMOUNT - REFERRER_AMOUNT, "merchant gets remainder");
        assertEq(token.balanceOf(address(proxy)), 0, "proxy retains nothing");
    }

    function test_settle_fullToReferrer() public {
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0), payer, _witness(merchant, referrer, TRANSFER_AMOUNT, block.timestamp - 1), _sig()
        );
        assertEq(token.balanceOf(referrer), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(merchant), 0);
    }

    function test_revert_zeroReferrer() public {
        vm.expectRevert(X402ReferralSplitProxy.InvalidReferrer.selector);
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0), payer, _witness(merchant, address(0), REFERRER_AMOUNT, block.timestamp - 1), _sig()
        );
    }

    function test_revert_zeroMerchant() public {
        vm.expectRevert(x402BasePermit2Proxy.InvalidDestination.selector);
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0), payer, _witness(address(0), referrer, REFERRER_AMOUNT, block.timestamp - 1), _sig()
        );
    }

    function test_revert_referrerAmountZero() public {
        vm.expectRevert(X402ReferralSplitProxy.InvalidReferrerAmount.selector);
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0), payer, _witness(merchant, referrer, 0, block.timestamp - 1), _sig()
        );
    }

    function test_revert_referrerAmountExceedsTotal() public {
        vm.expectRevert(X402ReferralSplitProxy.InvalidReferrerAmount.selector);
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0),
            payer,
            _witness(merchant, referrer, TRANSFER_AMOUNT + 1, block.timestamp - 1),
            _sig()
        );
    }

    function test_revert_paymentTooEarly() public {
        vm.expectRevert(x402BasePermit2Proxy.PaymentTooEarly.selector);
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0),
            payer,
            _witness(merchant, referrer, REFERRER_AMOUNT, block.timestamp + 60),
            _sig()
        );
    }

    function test_revert_zeroAmount() public {
        vm.expectRevert(x402BasePermit2Proxy.InvalidAmount.selector);
        proxy.settle(_permit(0, 0), payer, _witness(merchant, referrer, 1, block.timestamp - 1), _sig());
    }

    function test_revert_duplicateRecipient() public {
        vm.expectRevert(X402ReferralSplitProxy.DuplicateRecipient.selector);
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0), payer, _witness(merchant, merchant, REFERRER_AMOUNT, block.timestamp - 1), _sig()
        );
    }

    function test_reentrantTokenBlockedByGuard() public {
        // A token that re-enters settle() during the outbound transfer must be
        // blocked by nonReentrant; the mock's require(!ok) fails the test if not.
        MockReentrantToken t = new MockReentrantToken();
        t.mint(payer, MINT_AMOUNT);
        vm.prank(payer);
        t.approve(address(mockPermit2), type(uint256).max);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(t), amount: TRANSFER_AMOUNT}),
            nonce: 0,
            deadline: block.timestamp + 3600
        });
        X402ReferralSplitProxy.Witness memory w = _witness(merchant, referrer, REFERRER_AMOUNT, block.timestamp - 1);

        // Arm the token to re-enter settle() with the same args during transfer.
        t.arm(address(proxy), abi.encodeWithSelector(proxy.settle.selector, permit, payer, w, _sig()));

        // Outer settle completes; the re-entry is rejected by the guard (asserted in the mock).
        proxy.settle(permit, payer, w, _sig());
        assertEq(t.balanceOf(referrer), REFERRER_AMOUNT);
        assertEq(t.balanceOf(merchant), TRANSFER_AMOUNT - REFERRER_AMOUNT);
    }

    function test_revert_feeOnTransferIsInexact() public {
        // A fee-on-transfer token makes recipients receive less than the signed
        // amounts; the balance-delta check must revert rather than emit a lie.
        MockFeeERC20 feeToken = new MockFeeERC20();
        feeToken.mint(payer, MINT_AMOUNT);
        vm.prank(payer);
        feeToken.approve(address(mockPermit2), type(uint256).max);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(feeToken), amount: TRANSFER_AMOUNT}),
            nonce: 0,
            deadline: block.timestamp + 3600
        });
        vm.expectRevert(X402ReferralSplitProxy.InexactTransfer.selector);
        proxy.settle(permit, payer, _witness(merchant, referrer, REFERRER_AMOUNT, block.timestamp - 1), _sig());
    }

    function test_revert_selfRecipientMerchant() public {
        vm.expectRevert(X402ReferralSplitProxy.SelfRecipient.selector);
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0),
            payer,
            _witness(address(proxy), referrer, REFERRER_AMOUNT, block.timestamp - 1),
            _sig()
        );
    }

    function test_revert_selfRecipientReferrer() public {
        vm.expectRevert(X402ReferralSplitProxy.SelfRecipient.selector);
        proxy.settle(
            _permit(TRANSFER_AMOUNT, 0),
            payer,
            _witness(merchant, address(proxy), REFERRER_AMOUNT, block.timestamp - 1),
            _sig()
        );
    }

    // ----- Fuzz -----

    /// @notice For any valid (amount, referrerAmount), the split is exact and nothing is retained.
    function testFuzz_settle_splitsExactly(uint256 amount, uint256 referrerAmount) public {
        amount = bound(amount, 1, MINT_AMOUNT);
        referrerAmount = bound(referrerAmount, 1, amount);

        proxy.settle(
            _permit(amount, 0), payer, _witness(merchant, referrer, referrerAmount, block.timestamp - 1), _sig()
        );

        assertEq(token.balanceOf(referrer), referrerAmount);
        assertEq(token.balanceOf(merchant), amount - referrerAmount);
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(token.balanceOf(referrer) + token.balanceOf(merchant), amount);
    }

    /// @notice Any referrerAmount outside (0, amount] must revert.
    function testFuzz_settle_revertsOnInvalidReferrerAmount(uint256 amount, uint256 referrerAmount) public {
        amount = bound(amount, 1, MINT_AMOUNT);
        vm.assume(referrerAmount == 0 || referrerAmount > amount);

        vm.expectRevert(X402ReferralSplitProxy.InvalidReferrerAmount.selector);
        proxy.settle(
            _permit(amount, 0), payer, _witness(merchant, referrer, referrerAmount, block.timestamp - 1), _sig()
        );
    }
}
