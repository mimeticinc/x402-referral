// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {X402ReferralSplitProxy} from "../src/X402ReferralSplitProxy.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title X402ReferralSplitProxyForkTest
/// @notice Fork tests against the real Permit2 deployment, with real EIP-712
///         signatures, proving the witness binding cannot be tampered with.
/// @dev Run with: forge test --match-contract X402ReferralSplitProxyForkTest --fork-url $BASE_RPC_URL
///      (canonical Permit2 exists on Base, Base Sepolia, mainnet, etc.)
///      Without --fork-url the chain id is 31337 and every test no-ops via onlyFork.
contract X402ReferralSplitProxyForkTest is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    // Must match X402ReferralSplitProxy.WITNESS_TYPE_STRING exactly.
    bytes32 constant PERMIT_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Witness witness)TokenPermissions(address token,uint256 amount)Witness(address merchant,address referrer,uint256 referrerAmount,uint256 validAfter,bytes32 attributionId)"
    );
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    X402ReferralSplitProxy public proxy;
    MockERC20 public token;

    uint256 public payerKey;
    address public payer;
    address public merchant;
    address public referrer;

    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant TRANSFER_AMOUNT = 100e6;
    uint256 constant SPLIT_BPS = 2000;
    uint256 constant REFERRER_AMOUNT = (TRANSFER_AMOUNT * SPLIT_BPS) / 10_000; // 20 USDC
    bytes32 constant ATTRIBUTION = keccak256("att_fork");

    function setUp() public {
        if (block.chainid == 31_337) return;
        require(PERMIT2.code.length > 0, "Permit2 not deployed");

        payerKey = uint256(keccak256("x402-referral-test-payer"));
        payer = vm.addr(payerKey);
        merchant = makeAddr("merchant");
        referrer = makeAddr("referrer");

        proxy = new X402ReferralSplitProxy(PERMIT2);
        token = new MockERC20("USDC", "USDC", 6);
        token.mint(payer, MINT_AMOUNT);

        vm.prank(payer);
        token.approve(PERMIT2, type(uint256).max);
    }

    modifier onlyFork() {
        if (block.chainid == 31_337) return;
        _;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Permit2"), block.chainid, PERMIT2));
    }

    function _nonce(uint256 salt) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp, block.number, salt)));
    }

    function _witness(uint256 validAfter) internal view returns (X402ReferralSplitProxy.Witness memory) {
        return X402ReferralSplitProxy.Witness({
            merchant: merchant,
            referrer: referrer,
            referrerAmount: REFERRER_AMOUNT,
            validAfter: validAfter,
            attributionId: ATTRIBUTION
        });
    }

    function _sign(uint256 amount, uint256 nonce, uint256 deadline, X402ReferralSplitProxy.Witness memory w)
        internal
        view
        returns (bytes memory)
    {
        bytes32 witnessHash = keccak256(
            abi.encode(proxy.WITNESS_TYPEHASH(), w.merchant, w.referrer, w.referrerAmount, w.validAfter, w.attributionId)
        );
        bytes32 tokenHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, address(token), amount));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, tokenHash, address(proxy), nonce, deadline, witnessHash));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
    }

    function test_fork_settleSplitsWithRealPermit2() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(1);
        uint256 deadline = t + 3600;
        X402ReferralSplitProxy.Witness memory w = _witness(t - 60);
        bytes memory sig = _sign(TRANSFER_AMOUNT, nonce, deadline, w);

        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, w, sig);

        assertEq(token.balanceOf(referrer), REFERRER_AMOUNT, "referrer commission");
        assertEq(token.balanceOf(merchant), TRANSFER_AMOUNT - REFERRER_AMOUNT, "merchant remainder");
        assertEq(token.balanceOf(address(proxy)), 0, "no retention");
    }

    function test_fork_rejectsWrongSigner() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(2);
        uint256 deadline = t + 3600;
        X402ReferralSplitProxy.Witness memory w = _witness(t - 60);

        bytes32 witnessHash = keccak256(
            abi.encode(proxy.WITNESS_TYPEHASH(), w.merchant, w.referrer, w.referrerAmount, w.validAfter, w.attributionId)
        );
        bytes32 tokenHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, address(token), TRANSFER_AMOUNT));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, tokenHash, address(proxy), nonce, deadline, witnessHash));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xdeadbeef, digest);

        vm.expectRevert();
        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, w, abi.encodePacked(r, s, v));
    }

    function test_fork_rejectsReplayedNonce() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(3);
        uint256 deadline = t + 3600;
        X402ReferralSplitProxy.Witness memory w = _witness(t - 60);
        bytes memory sig = _sign(TRANSFER_AMOUNT, nonce, deadline, w);

        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, w, sig);
        vm.expectRevert();
        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, w, sig);
    }

    function test_fork_rejectsExpiredDeadline() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(4);
        uint256 deadline = t - 60; // expired
        X402ReferralSplitProxy.Witness memory w = _witness(t - 120);
        bytes memory sig = _sign(TRANSFER_AMOUNT, nonce, deadline, w);

        vm.expectRevert();
        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, w, sig);
    }

    // ----- Tamper tests: any change to a signed witness field invalidates the signature -----

    function test_fork_preventsReferrerTampering() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(5);
        uint256 deadline = t + 3600;
        X402ReferralSplitProxy.Witness memory signed = _witness(t - 60);
        bytes memory sig = _sign(TRANSFER_AMOUNT, nonce, deadline, signed);

        X402ReferralSplitProxy.Witness memory tampered = signed;
        tampered.referrer = makeAddr("attacker");

        vm.expectRevert();
        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, tampered, sig);
    }

    function test_fork_preventsMerchantTampering() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(6);
        uint256 deadline = t + 3600;
        X402ReferralSplitProxy.Witness memory signed = _witness(t - 60);
        bytes memory sig = _sign(TRANSFER_AMOUNT, nonce, deadline, signed);

        X402ReferralSplitProxy.Witness memory tampered = signed;
        tampered.merchant = makeAddr("attacker");

        vm.expectRevert();
        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, tampered, sig);
    }

    function test_fork_preventsReferrerAmountTampering() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(7);
        uint256 deadline = t + 3600;
        X402ReferralSplitProxy.Witness memory signed = _witness(t - 60);
        bytes memory sig = _sign(TRANSFER_AMOUNT, nonce, deadline, signed);

        // Attacker tries to skim a larger commission than was signed.
        X402ReferralSplitProxy.Witness memory tampered = signed;
        tampered.referrerAmount = TRANSFER_AMOUNT;

        vm.expectRevert();
        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, tampered, sig);
    }

    function test_fork_preventsAttributionTampering() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(8);
        uint256 deadline = t + 3600;
        X402ReferralSplitProxy.Witness memory signed = _witness(t - 60);
        bytes memory sig = _sign(TRANSFER_AMOUNT, nonce, deadline, signed);

        X402ReferralSplitProxy.Witness memory tampered = signed;
        tampered.attributionId = keccak256("different");

        vm.expectRevert();
        proxy.settle(_permit(TRANSFER_AMOUNT, nonce, deadline), payer, tampered, sig);
    }

    function test_fork_preventsAmountTampering() public onlyFork {
        uint256 t = block.timestamp;
        uint256 nonce = _nonce(9);
        uint256 deadline = t + 3600;
        X402ReferralSplitProxy.Witness memory w = _witness(t - 60);
        bytes memory sig = _sign(TRANSFER_AMOUNT, nonce, deadline, w);

        // Attacker inflates the permitted amount beyond what was signed.
        vm.expectRevert();
        proxy.settle(_permit(TRANSFER_AMOUNT * 2, nonce, deadline), payer, w, sig);
    }
}
