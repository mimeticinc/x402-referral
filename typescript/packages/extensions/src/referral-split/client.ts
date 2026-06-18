/**
 * Client/facilitator helpers for extracting referral terms from x402 messages.
 */

import { REFERRAL_SPLIT, isReferralSplitInfo, type ReferralSplitInfo } from "./types";
import { computeReferralSplit } from "./split";
import { hashAttributionId, type ReferralWitness } from "./witness";

/** Shape of the relevant slice of a PaymentRequired / PaymentPayload message. */
interface WithExtensions {
  extensions?: Record<string, { info?: unknown } | undefined>;
}

/**
 * Extract advertised referral terms from a PaymentRequired (or echoed
 * PaymentPayload). Returns null when the extension is absent or malformed.
 *
 * @param message - A PaymentRequired/PaymentPayload-shaped object with extensions.
 * @returns The referral terms, or null when absent or malformed.
 */
export function extractReferralSplitInfo(
  message: WithExtensions | undefined | null,
): ReferralSplitInfo | null {
  const info = message?.extensions?.[REFERRAL_SPLIT]?.info;
  return isReferralSplitInfo(info) ? info : null;
}

/**
 * Confirm a payer's echoed terms match what the server advertised, on the
 * observability fields carried in the PaymentPayload echo (referrer / splitBps /
 * attributionId). The echo does not carry `merchant`, and is NOT authenticated —
 * merchant authentication is enforced by the signed witness, so use
 * `referralWitnessMatchesTerms` for any settlement decision.
 *
 * @param advertised - The terms the server advertised.
 * @param echoed - The terms the payer echoed back.
 * @returns True when referrer, splitBps, and attributionId match.
 */
export function referralTermsMatch(
  advertised: ReferralSplitInfo,
  echoed: ReferralSplitInfo,
): boolean {
  return (
    advertised.referrer.toLowerCase() === echoed.referrer.toLowerCase() &&
    advertised.splitBps === echoed.splitBps &&
    advertised.attributionId === echoed.attributionId
  );
}

/**
 * Check that a Permit2 witness encodes exactly the advertised referral terms for
 * a given amount (merchant, referrer, referrerAmount, attribution hash).
 *
 * IMPORTANT: this is necessary but NOT sufficient to authorize settlement. It
 * does not verify the Permit2 signature itself, nor that `spender == splitter`,
 * `token == asset`, the signed amount, `deadline`, or `validAfter`. The caller
 * MUST also verify the signature and those authorization fields via the standard
 * x402 Permit2 verification path before settling.
 *
 * @param advertised - The terms the server advertised (must include merchant).
 * @param amount - The total payment amount in atomic units (decimal string or bigint).
 * @param witness - The witness the payer signed.
 * @returns True only when the witness binds exactly the advertised settlement tuple.
 */
export function referralWitnessMatchesTerms(
  advertised: ReferralSplitInfo,
  amount: string | bigint,
  witness: ReferralWitness,
): boolean {
  if (!advertised.merchant) return false;
  const { referrerAmount } = computeReferralSplit(amount, advertised.splitBps);
  return (
    witness.merchant.toLowerCase() === advertised.merchant.toLowerCase() &&
    witness.referrer.toLowerCase() === advertised.referrer.toLowerCase() &&
    witness.referrerAmount === referrerAmount &&
    witness.attributionId.toLowerCase() ===
      hashAttributionId(advertised.attributionId).toLowerCase()
  );
}
