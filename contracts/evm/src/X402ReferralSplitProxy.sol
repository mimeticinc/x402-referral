// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {x402BasePermit2Proxy} from "./x402BasePermit2Proxy.sol";
import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";

/**
 * @title X402ReferralSplitProxy
 * @notice Trustless x402 payment proxy that splits a single payment between a
 *         merchant and a referrer, settling the referrer's commission atomically
 *         on-chain.
 *
 * @dev Implements the x402 `referral-split` extension
 *      (specs/extensions/referral-split.md). Like x402ExactPermit2Proxy it uses
 *      the Permit2 "witness" pattern, but the witness binds BOTH recipients and
 *      the exact referrer amount, so neither the facilitator nor this contract
 *      can redirect funds or alter the split — the payer's signature authorizes
 *      precisely this distribution.
 *
 *      Flow: the full permitted amount is pulled to this contract, then
 *      `referrerAmount` is forwarded to `referrer` and the remainder to
 *      `merchant`, emitting `ReferralSettled` as the public proof of payment for
 *      `attributionId`.
 *
 * @author x402-referral
 */
contract X402ReferralSplitProxy is x402BasePermit2Proxy {
    using SafeERC20 for IERC20;

    /// @notice EIP-712 type string for the referral witness (matches the TS extension).
    string public constant WITNESS_TYPE_STRING =
        "Witness witness)TokenPermissions(address token,uint256 amount)"
        "Witness(address merchant,address referrer,uint256 referrerAmount,uint256 validAfter,bytes32 attributionId)";

    /// @notice EIP-712 typehash for the referral witness struct.
    bytes32 public constant WITNESS_TYPEHASH = keccak256(
        "Witness(address merchant,address referrer,uint256 referrerAmount,uint256 validAfter,bytes32 attributionId)"
    );

    /// @notice Emitted on a successful referral settlement; the proof of commission payment.
    /// @param attributionId Conversion id (keccak256 of the off-chain attribution id), indexed.
    /// @param merchant The merchant recipient, indexed.
    /// @param referrer The referrer recipient, indexed.
    /// @param token The ERC-20 token paid.
    /// @param merchantAmount Amount sent to the merchant.
    /// @param referrerAmount Amount sent to the referrer.
    /// @param payer The token owner who funded the payment.
    event ReferralSettled(
        bytes32 indexed attributionId,
        address indexed merchant,
        address indexed referrer,
        address token,
        uint256 merchantAmount,
        uint256 referrerAmount,
        address payer
    );

    /// @notice Thrown when the referrer address is zero.
    error InvalidReferrer();

    /// @notice Thrown when referrerAmount is zero or exceeds the permitted amount.
    error InvalidReferrerAmount();

    /// @notice Thrown when a recipient is the splitter itself (funds would be stuck).
    error SelfRecipient();

    /// @notice Thrown when merchant and referrer are the same address.
    error DuplicateRecipient();

    /// @notice Thrown when a recipient did not receive exactly its signed amount
    ///         (e.g. a fee-on-transfer/rebasing token); the settlement is reverted.
    error InexactTransfer();

    /**
     * @notice Witness data binding the split into the payer's Permit2 signature.
     * @param merchant Destination for the merchant's share (immutable once signed).
     * @param referrer Destination for the referrer's commission (immutable once signed).
     * @param referrerAmount Exact commission in token units (== floor(amount*splitBps/10000)).
     * @param validAfter Earliest timestamp when payment can be settled.
     * @param attributionId keccak256 of the off-chain attribution id.
     */
    struct Witness {
        address merchant;
        address referrer;
        uint256 referrerAmount;
        uint256 validAfter;
        bytes32 attributionId;
    }

    constructor(
        address _permit2
    ) x402BasePermit2Proxy(_permit2) {}

    /**
     * @notice Settle an x402 payment, splitting it between merchant and referrer.
     * @dev The full `permit.permitted.amount` is transferred to this contract via
     *      Permit2, then split per the signed witness. Reverts if the referrer
     *      share is zero or exceeds the total.
     * @param permit The Permit2 transfer authorization (the full payment amount).
     * @param owner The token owner (payer).
     * @param witness The split parameters, bound into the payer's signature.
     * @param signature The payer's Permit2 witness signature.
     */
    function settle(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        address owner,
        Witness calldata witness,
        bytes calldata signature
    ) external nonReentrant {
        if (witness.referrer == address(0)) revert InvalidReferrer();
        if (witness.merchant == address(0)) revert InvalidDestination();
        if (owner == address(0)) revert InvalidOwner();
        // Reject self-recipients: funds sent to this proxy would be permanently stuck.
        if (witness.merchant == address(this) || witness.referrer == address(this)) {
            revert SelfRecipient();
        }
        // Distinct recipients so the exact-amount balance checks below are unambiguous.
        if (witness.merchant == witness.referrer) revert DuplicateRecipient();

        uint256 amount = permit.permitted.amount;
        if (amount == 0) revert InvalidAmount();
        if (witness.referrerAmount == 0 || witness.referrerAmount > amount) {
            revert InvalidReferrerAmount();
        }
        if (block.timestamp < witness.validAfter) revert PaymentTooEarly();

        bytes32 witnessHash = keccak256(
            abi.encode(
                WITNESS_TYPEHASH,
                witness.merchant,
                witness.referrer,
                witness.referrerAmount,
                witness.validAfter,
                witness.attributionId
            )
        );

        // Pull the full amount to this contract; the witness binds the split, so
        // the facilitator cannot alter recipients or amounts.
        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount});

        PERMIT2.permitWitnessTransferFrom(
            permit, transferDetails, owner, witnessHash, WITNESS_TYPE_STRING, signature
        );

        uint256 merchantAmount = amount - witness.referrerAmount;
        _distribute(permit.permitted.token, witness, merchantAmount);

        emit ReferralSettled(
            witness.attributionId,
            witness.merchant,
            witness.referrer,
            permit.permitted.token,
            merchantAmount,
            witness.referrerAmount,
            owner
        );
    }

    /**
     * @notice Transfer each share and enforce that recipients received exactly the
     *         signed amounts (so the emitted amounts are truthful for any token).
     * @dev A fee-on-transfer/rebasing token causes a revert here rather than a
     *      silent shortfall. Split into a helper to keep `settle` within stack limits.
     * @param tokenAddr The ERC-20 being split.
     * @param witness The signed split parameters.
     * @param merchantAmount The merchant's share (amount - referrerAmount).
     */
    function _distribute(address tokenAddr, Witness calldata witness, uint256 merchantAmount) internal {
        IERC20 token = IERC20(tokenAddr);
        uint256 referrerBefore = token.balanceOf(witness.referrer);
        uint256 merchantBefore = token.balanceOf(witness.merchant);

        token.safeTransfer(witness.referrer, witness.referrerAmount);
        if (merchantAmount > 0) {
            token.safeTransfer(witness.merchant, merchantAmount);
        }

        if (token.balanceOf(witness.referrer) - referrerBefore != witness.referrerAmount) {
            revert InexactTransfer();
        }
        if (merchantAmount > 0 && token.balanceOf(witness.merchant) - merchantBefore != merchantAmount) {
            revert InexactTransfer();
        }
    }
}
