// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {X402ReferralSplitProxy} from "../../src/X402ReferralSplitProxy.sol";
import {ISignatureTransfer} from "../../src/interfaces/ISignatureTransfer.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Drives randomized settle() calls; tracks how much was settled in total.
contract X402ReferralSplitHandler is Test {
    X402ReferralSplitProxy public proxy;
    MockPermit2 public mockPermit2;
    MockERC20 public token;

    address public payer;
    address public merchant;
    address public referrer;

    uint256 public totalSettled;
    uint256 public settleCallCount;

    constructor(
        X402ReferralSplitProxy _proxy,
        MockPermit2 _mockPermit2,
        MockERC20 _token,
        address _payer,
        address _merchant,
        address _referrer
    ) {
        proxy = _proxy;
        mockPermit2 = _mockPermit2;
        token = _token;
        payer = _payer;
        merchant = _merchant;
        referrer = _referrer;
    }

    function settle(uint256 amount, uint256 splitBps, uint256 nonce) external {
        amount = bound(amount, 1, token.balanceOf(payer));
        if (amount == 0) return;
        splitBps = bound(splitBps, 1, 10_000);
        uint256 referrerAmount = (amount * splitBps) / 10_000;
        if (referrerAmount == 0) referrerAmount = 1; // contract rejects 0
        if (referrerAmount > amount) referrerAmount = amount;

        uint256 t = block.timestamp;
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: nonce,
            deadline: t + 3600
        });

        X402ReferralSplitProxy.Witness memory witness = X402ReferralSplitProxy.Witness({
            merchant: merchant,
            referrer: referrer,
            referrerAmount: referrerAmount,
            validAfter: t > 60 ? t - 60 : 0,
            attributionId: keccak256(abi.encode(nonce))
        });

        bytes memory sig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        try proxy.settle(permit, payer, witness, sig) {
            totalSettled += amount;
            settleCallCount++;
        } catch {}
    }
}

contract X402ReferralSplitInvariantsTest is Test {
    X402ReferralSplitProxy public proxy;
    MockPermit2 public mockPermit2;
    MockERC20 public token;
    X402ReferralSplitHandler public handler;

    address public payer;
    address public merchant;
    address public referrer;

    uint256 constant MINT_AMOUNT = 1_000_000e6;

    function setUp() public {
        payer = makeAddr("payer");
        merchant = makeAddr("merchant");
        referrer = makeAddr("referrer");

        mockPermit2 = new MockPermit2();
        proxy = new X402ReferralSplitProxy(address(mockPermit2));
        token = new MockERC20("USDC", "USDC", 6);

        token.mint(payer, MINT_AMOUNT);
        vm.prank(payer);
        token.approve(address(mockPermit2), type(uint256).max);
        mockPermit2.setShouldActuallyTransfer(true);

        handler = new X402ReferralSplitHandler(proxy, mockPermit2, token, payer, merchant, referrer);
        targetContract(address(handler));
    }

    /// @notice The splitter must never retain tokens; everything flows to merchant/referrer.
    function invariant_proxyNeverHoldsTokens() public view {
        assertEq(token.balanceOf(address(proxy)), 0);
    }

    /// @notice No tokens are created or destroyed across all settlements.
    function invariant_tokenConservation() public view {
        uint256 total = token.balanceOf(payer) + token.balanceOf(merchant) + token.balanceOf(referrer)
            + token.balanceOf(address(proxy)) + token.balanceOf(address(mockPermit2));
        assertEq(total, MINT_AMOUNT);
    }

    /// @notice Every settled unit landed with exactly one of merchant or referrer.
    function invariant_splitConservation() public view {
        assertEq(token.balanceOf(merchant) + token.balanceOf(referrer), handler.totalSettled());
    }

    /// @notice The referrer can never receive more than the total settled.
    function invariant_referrerNeverExceedsSettled() public view {
        assertLe(token.balanceOf(referrer), handler.totalSettled());
    }
}
