// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {X402ReferralSplitProxy} from "../src/X402ReferralSplitProxy.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/**
 * @title DemoReferralSettlement
 * @notice End-to-end demo of a referral-split settlement on real Permit2.
 * @dev Pure simulation — run against a fork, no broadcast, no funds needed:
 *        forge script script/DemoReferralSettlement.s.sol:DemoReferralSettlement \
 *          --fork-url https://sepolia.base.org -vv
 *
 *      Narrative: merchant advertises a 20% referral; the payer signs a Permit2
 *      witness binding the exact split; a facilitator settles; the contract pays
 *      referrer + merchant atomically and emits ReferralSettled.
 */
contract DemoReferralSettlement is Script {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 constant PERMIT_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Witness witness)TokenPermissions(address token,uint256 amount)Witness(address merchant,address referrer,uint256 referrerAmount,uint256 validAfter,bytes32 attributionId)"
    );
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    // State (avoids stack-too-deep in run()).
    X402ReferralSplitProxy internal splitter;
    MockERC20 internal usdc;
    uint256 internal payerKey;
    address internal payer;
    address internal merchant;
    address internal referrer;
    uint256 internal amount = 100e6; // 100 USDC
    uint256 internal splitBps = 2000; // 20%
    uint256 internal referrerAmount;
    bytes32 internal attributionId = keccak256("att_demo_0001");
    uint256 internal nonce;
    uint256 internal deadline;

    function run() public {
        require(PERMIT2.code.length > 0, "Run against a fork where Permit2 is deployed (e.g. Base Sepolia)");
        _setup();
        _logHeader();
        _signAndSettle();
        _report();
    }

    function _setup() internal {
        payerKey = uint256(keccak256("demo-payer"));
        payer = vm.addr(payerKey);
        merchant = makeAddr("merchant");
        referrer = makeAddr("referrer");
        referrerAmount = (amount * splitBps) / 10_000;

        splitter = new X402ReferralSplitProxy(PERMIT2);
        usdc = new MockERC20("Demo USDC", "USDC", 6);
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(PERMIT2, type(uint256).max);

        nonce = uint256(keccak256(abi.encodePacked(block.timestamp, "demo")));
        deadline = block.timestamp + 3600;
    }

    function _logHeader() internal view {
        console2.log("=== x402 referral-split demo ===");
        console2.log("chainId        ", block.chainid);
        console2.log("splitter       ", address(splitter));
        console2.log("payer          ", payer);
        console2.log("merchant       ", merchant);
        console2.log("referrer       ", referrer);
        console2.log("amount (6dp)   ", amount);
        console2.log("splitBps       ", splitBps);
        console2.log("referrerAmount ", referrerAmount);
    }

    function _witness() internal view returns (X402ReferralSplitProxy.Witness memory) {
        return X402ReferralSplitProxy.Witness({
            merchant: merchant,
            referrer: referrer,
            referrerAmount: referrerAmount,
            validAfter: 0,
            attributionId: attributionId
        });
    }

    function _signAndSettle() internal {
        X402ReferralSplitProxy.Witness memory w = _witness();
        bytes memory sig = _sign(w);
        console2.log("payer signed witness; sig len", sig.length);

        console2.log("--- before ---");
        console2.log("payer    ", usdc.balanceOf(payer));
        console2.log("merchant ", usdc.balanceOf(merchant));
        console2.log("referrer ", usdc.balanceOf(referrer));

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdc), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
        // Caller is the facilitator (not the payer) — the signature is the authority.
        splitter.settle(permit, payer, w, sig);
    }

    function _report() internal view {
        console2.log("--- after ---");
        console2.log("payer    ", usdc.balanceOf(payer));
        console2.log("merchant ", usdc.balanceOf(merchant));
        console2.log("referrer ", usdc.balanceOf(referrer));
        console2.log("splitter ", usdc.balanceOf(address(splitter)));

        require(usdc.balanceOf(referrer) == referrerAmount, "referrer not paid exactly");
        require(usdc.balanceOf(merchant) == amount - referrerAmount, "merchant not paid remainder");
        require(usdc.balanceOf(address(splitter)) == 0, "splitter retained funds");
        console2.log("OK: atomic referral split settled on real Permit2");
    }

    function _sign(X402ReferralSplitProxy.Witness memory w) internal view returns (bytes memory) {
        bytes32 witnessHash = keccak256(
            abi.encode(
                splitter.WITNESS_TYPEHASH(), w.merchant, w.referrer, w.referrerAmount, w.validAfter, w.attributionId
            )
        );
        bytes32 tokenHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, address(usdc), amount));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, tokenHash, address(splitter), nonce, deadline, witnessHash));
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Permit2"), block.chainid, PERMIT2));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
