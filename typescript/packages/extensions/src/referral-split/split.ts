/**
 * Pure split arithmetic for the referral-split extension.
 *
 * All amounts are atomic token units (e.g. USDC has 6 decimals) handled as
 * bigint to avoid floating-point error. The referrer's cut is floored, so the
 * merchant receives the remainder — payments never over-distribute.
 */

import { BPS_DENOMINATOR, type ReferralSplitAmounts } from "./types";

const EVM_ADDRESS = /^0x[a-fA-F0-9]{40}$/;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** Thrown when split inputs are invalid. */
export class ReferralSplitError extends Error {
  override name = "ReferralSplitError";
}

/**
 * Validate that `splitBps` is an integer in the open-top range 1..10000.
 *
 * @param splitBps - Referrer share in basis points to validate.
 */
export function assertValidBps(splitBps: number): void {
  if (!Number.isInteger(splitBps) || splitBps < 1 || splitBps > BPS_DENOMINATOR) {
    throw new ReferralSplitError(
      `splitBps must be an integer in [1, ${BPS_DENOMINATOR}], got ${splitBps}`,
    );
  }
}

/**
 * Validate an EVM address shape (checksum not enforced here).
 *
 * @param address - The candidate address string.
 * @param label - Field name used in the error message.
 */
export function assertAddress(address: string, label: string): void {
  if (!EVM_ADDRESS.test(address)) {
    throw new ReferralSplitError(`${label} is not a valid EVM address: ${address}`);
  }
  if (address.toLowerCase() === ZERO_ADDRESS) {
    throw new ReferralSplitError(`${label} must not be the zero address`);
  }
}

/**
 * Compute the referrer/merchant split for a total payment amount.
 *
 * referrerAmount = floor(total * splitBps / 10000)
 * merchantAmount = total - referrerAmount
 *
 * @param amount - Total payment in atomic units (decimal string or bigint).
 * @param splitBps - Referrer share in basis points (1..10000).
 * @returns The merchant and referrer amounts and the original total, as decimal strings.
 */
export function computeReferralSplit(
  amount: string | bigint,
  splitBps: number,
): ReferralSplitAmounts {
  assertValidBps(splitBps);

  let total: bigint;
  try {
    total = typeof amount === "bigint" ? amount : BigInt(amount);
  } catch {
    throw new ReferralSplitError(`amount is not a valid integer: ${amount}`);
  }
  if (total <= 0n) {
    throw new ReferralSplitError(`amount must be positive, got ${total}`);
  }

  const referrer = (total * BigInt(splitBps)) / BigInt(BPS_DENOMINATOR);
  const merchant = total - referrer;

  return {
    referrerAmount: referrer.toString(),
    merchantAmount: merchant.toString(),
    totalAmount: total.toString(),
  };
}
