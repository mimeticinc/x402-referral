/**
 * x402 Referral-Split Extension
 *
 * Attribute an x402 payment to a referrer and settle the commission atomically
 * on-chain via the X402ReferralSplitProxy contract. See
 * specs/extensions/referral-split.md.
 */

// Types
export {
  REFERRAL_SPLIT,
  BPS_DENOMINATOR,
  isReferralSplitInfo,
  type ReferralSplitInfo,
  type ReferralSplitExtension,
  type ReferralSplitAmounts,
} from "./types";

// Pure split arithmetic
export { computeReferralSplit, assertValidBps, assertAddress, ReferralSplitError } from "./split";

// Server (advertise terms)
export {
  REFERRAL_SPLIT_SCHEMA,
  validateReferralSplitInfo,
  declareReferralSplitExtension,
} from "./server";

// Client / facilitator (extract & verify terms)
export {
  extractReferralSplitInfo,
  referralTermsMatch,
  referralWitnessMatchesTerms,
} from "./client";

// Permit2 witness binding (kept in lockstep with the Solidity contract)
export {
  WITNESS_TYPE_STRING,
  WITNESS_TYPE,
  PERMIT2_ADDRESS,
  PERMIT2_WITNESS_TYPES,
  buildReferralWitness,
  buildReferralPermit2TypedData,
  hashAttributionId,
  type ReferralWitness,
} from "./witness";
