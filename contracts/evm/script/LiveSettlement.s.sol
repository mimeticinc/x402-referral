// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {X402ReferralSplitProxy} from "../src/X402ReferralSplitProxy.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";

/**
 * @title LiveSettlement
 * @notice Real on-chain referral settlement against the deployed splitter.
 * @dev    PAYER_KEY=0x... forge script script/LiveSettlement.s.sol:LiveSettlement \
 *           --rpc-url https://sepolia.base.org --broadcast
 *         Approves Permit2, signs the witness with the payer key, and settles —
 *         splitting real testnet USDC to merchant + referrer.
 */
contract LiveSettlement is Script {
    address constant SPLITTER = 0x4AdE44726d54346A8d1899fcFa1aa20FC867F2af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // Base Sepolia USDC

    bytes32 constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 constant PERMIT_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Witness witness)TokenPermissions(address token,uint256 amount)Witness(address merchant,address referrer,uint256 referrerAmount,uint256 validAfter,bytes32 attributionId)"
    );
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    uint256 internal payerKey;
    address internal payer;
    address internal merchant;
    address internal referrer;
    uint256 internal amount = 1_000_000; // 1 USDC
    uint256 internal referrerAmount = 200_000; // 20%
    bytes32 internal attributionId = keccak256("att_live_0001");
    uint256 internal nonce;
    uint256 internal deadline;

    function run() public {
        payerKey = vm.envUint("PAYER_KEY");
        payer = vm.addr(payerKey);
        merchant = vm.addr(uint256(keccak256("live-merchant")));
        referrer = vm.addr(uint256(keccak256("live-referrer")));
        nonce = uint256(keccak256(abi.encodePacked(block.timestamp, payer, "live")));
        deadline = block.timestamp + 3600;

        console2.log("payer    ", payer);
        console2.log("merchant ", merchant);
        console2.log("referrer ", referrer);
        console2.log("--- USDC before ---");
        console2.log("payer    ", IERC20(USDC).balanceOf(payer));
        console2.log("merchant ", IERC20(USDC).balanceOf(merchant));
        console2.log("referrer ", IERC20(USDC).balanceOf(referrer));

        X402ReferralSplitProxy.Witness memory w = X402ReferralSplitProxy.Witness({
            merchant: merchant,
            referrer: referrer,
            referrerAmount: referrerAmount,
            validAfter: 0,
            attributionId: attributionId
        });
        bytes memory sig = _sign(w);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: USDC, amount: amount}),
            nonce: nonce,
            deadline: deadline
        });

        vm.startBroadcast(payerKey);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        X402ReferralSplitProxy(SPLITTER).settle(permit, payer, w, sig);
        vm.stopBroadcast();

        console2.log("--- USDC after ---");
        console2.log("payer    ", IERC20(USDC).balanceOf(payer));
        console2.log("merchant ", IERC20(USDC).balanceOf(merchant));
        console2.log("referrer ", IERC20(USDC).balanceOf(referrer));
        console2.log("splitter ", IERC20(USDC).balanceOf(SPLITTER));
    }

    function _sign(X402ReferralSplitProxy.Witness memory w) internal view returns (bytes memory) {
        bytes32 witnessHash = keccak256(
            abi.encode(
                X402ReferralSplitProxy(SPLITTER).WITNESS_TYPEHASH(),
                w.merchant,
                w.referrer,
                w.referrerAmount,
                w.validAfter,
                w.attributionId
            )
        );
        bytes32 tokenHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, USDC, amount));
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, tokenHash, SPLITTER, nonce, deadline, witnessHash));
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Permit2"), block.chainid, PERMIT2));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
