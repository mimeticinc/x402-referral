/**
 * Resource-server helpers for the referral-split extension.
 *
 * A resource server uses `declareReferralSplitExtension` to advertise referral
 * terms in its `402 Payment Required` response. The `payTo` of the matching
 * `accepts` object MUST be the splitter contract address.
 */

import { REFERRAL_SPLIT, BPS_DENOMINATOR, type ReferralSplitInfo } from "./types";
import { assertValidBps, assertAddress, ReferralSplitError } from "./split";

/** JSON Schema advertised alongside the extension info (spec §PaymentRequired). */
export const REFERRAL_SPLIT_SCHEMA = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  type: "object",
  properties: {
    required: { type: "boolean" },
    merchant: { type: "string", pattern: "^0x[a-fA-F0-9]{40}$" },
    referrer: { type: "string", pattern: "^0x[a-fA-F0-9]{40}$" },
    splitBps: { type: "integer", minimum: 1, maximum: BPS_DENOMINATOR },
    attributionId: { type: "string", minLength: 1, maxLength: 128 },
    splitter: { type: "string", pattern: "^0x[a-fA-F0-9]{40}$" },
    network: { type: "string" },
  },
  required: ["merchant", "referrer", "splitBps", "attributionId", "splitter", "network"],
} as const;

/**
 * Validate referral terms a server intends to advertise.
 * Throws ReferralSplitError on any invalid field.
 *
 * @param info - The referral terms to validate.
 */
export function validateReferralSplitInfo(info: ReferralSplitInfo): void {
  assertValidBps(info.splitBps);
  assertAddress(info.referrer, "referrer");
  if (info.merchant !== undefined) assertAddress(info.merchant, "merchant");
  if (info.splitter !== undefined) assertAddress(info.splitter, "splitter");
  if (!info.attributionId || info.attributionId.length > 128) {
    throw new ReferralSplitError("attributionId must be 1..128 characters");
  }
  // Mirror the on-chain guards (DuplicateRecipient / SelfRecipient) so the server
  // never advertises terms the contract will reject at settlement.
  const eq = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
  if (eq(info.merchant, info.referrer)) {
    throw new ReferralSplitError("merchant and referrer must be different addresses");
  }
  if (eq(info.referrer, info.splitter) || eq(info.merchant, info.splitter)) {
    throw new ReferralSplitError("merchant and referrer must not be the splitter contract");
  }
}

/**
 * Build the `extensions["referral-split"]` entry for a PaymentRequired response.
 * `splitter` and `network` are required when advertising server-side.
 *
 * @param info - The referral terms to advertise (must include splitter and network).
 * @returns The extension entry keyed by "referral-split", ready to merge into extensions.
 */
export function declareReferralSplitExtension(
  info: ReferralSplitInfo,
): Record<string, { info: ReferralSplitInfo; schema: typeof REFERRAL_SPLIT_SCHEMA }> {
  validateReferralSplitInfo(info);
  if (!info.merchant || !info.splitter || !info.network) {
    throw new ReferralSplitError("server must advertise `merchant`, `splitter`, and `network`");
  }
  return {
    [REFERRAL_SPLIT]: {
      info: { required: false, ...info },
      schema: REFERRAL_SPLIT_SCHEMA,
    },
  };
}
