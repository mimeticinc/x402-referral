/**
 * Type definitions for the x402 Referral-Split Extension
 *
 * Based on: x402/specs/extensions/referral-split.md (v1.0)
 *
 * A resource server attributes a payment to a referrer (affiliate / marketplace /
 * discovery agent) and has the referrer's commission settled atomically on-chain
 * via the X402ReferralSplitProxy contract. The split is bound into the payer's
 * Permit2 witness, so the facilitator cannot alter it — the settlement tx is the
 * proof the referrer was paid.
 */

/** Extension identifier constant. */
export const REFERRAL_SPLIT = "referral-split";

/** Basis-point denominator (100% = 10000 bps). */
export const BPS_DENOMINATOR = 10000;

/**
 * Referral terms advertised by the resource server in `PaymentRequired`
 * (and echoed, minus on-chain-only fields, by the client in `PaymentPayload`).
 */
export interface ReferralSplitInfo {
  /** The authenticated merchant recipient (the real payee). Required server-side. */
  merchant?: string;
  /** Recipient of the commission (EVM address). */
  referrer: string;
  /** Referrer share in basis points, 1..10000 (2000 = 20%). */
  splitBps: number;
  /** Stable id binding this payment to a conversion in the affiliate ledger. */
  attributionId: string;
  /** The X402ReferralSplitProxy contract address. Required server-side. */
  splitter?: string;
  /** CAIP-2 network the splitter is deployed on, e.g. "eip155:84532". */
  network?: string;
  /** Whether routing through the splitter is mandatory. Default false. */
  required?: boolean;
}

/** The full extension entry as it appears under `extensions["referral-split"]`. */
export interface ReferralSplitExtension {
  info: ReferralSplitInfo;
  schema?: Record<string, unknown>;
}

/** Computed atomic-unit amounts for a split. Values are decimal strings. */
export interface ReferralSplitAmounts {
  /** Amount transferred to the merchant. */
  merchantAmount: string;
  /** Amount transferred to the referrer. */
  referrerAmount: string;
  /** The original total (merchantAmount + referrerAmount). */
  totalAmount: string;
}

/**
 * Type guard: a value is a well-formed ReferralSplitInfo.
 *
 * @param value - The value to test.
 * @returns True when value has the required referrer/splitBps/attributionId fields.
 */
export function isReferralSplitInfo(value: unknown): value is ReferralSplitInfo {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.referrer === "string" &&
    typeof v.splitBps === "number" &&
    typeof v.attributionId === "string"
  );
}
