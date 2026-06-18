/**
 * Permit2 witness binding for the referral-split extension.
 *
 * These constants MUST stay in lockstep with contracts/evm/src/X402ReferralSplitProxy.sol.
 * The witness binds merchant, referrer, the exact referrer amount, validity, and
 * attribution id into the payer's Permit2 signature, so neither the facilitator
 * nor the splitter can deviate from the advertised split.
 */

import { keccak256, toBytes, type Hex } from "viem";
import { computeReferralSplit, ReferralSplitError } from "./split";

/** EIP-712 type string appended to the Permit2 witness transfer (matches Solidity). */
export const WITNESS_TYPE_STRING =
  "Witness witness)TokenPermissions(address token,uint256 amount)" +
  "Witness(address merchant,address referrer,uint256 referrerAmount,uint256 validAfter,bytes32 attributionId)";

/** The standalone Witness struct type used to compute the witness hash. */
export const WITNESS_TYPE =
  "Witness(address merchant,address referrer,uint256 referrerAmount,uint256 validAfter,bytes32 attributionId)";

/** Canonical Permit2 contract address (same on every EVM chain). */
export const PERMIT2_ADDRESS: Hex = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

/**
 * EIP-712 `types` for a Permit2 `PermitWitnessTransferFrom` carrying the referral
 * Witness. Field order/types MUST match the Solidity `WITNESS_TYPE_STRING`.
 */
export const PERMIT2_WITNESS_TYPES = {
  PermitWitnessTransferFrom: [
    { name: "permitted", type: "TokenPermissions" },
    { name: "spender", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "witness", type: "Witness" },
  ],
  TokenPermissions: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
  ],
  Witness: [
    { name: "merchant", type: "address" },
    { name: "referrer", type: "address" },
    { name: "referrerAmount", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "attributionId", type: "bytes32" },
  ],
} as const;

/** Concrete witness values that get signed by the payer and verified on-chain. */
export interface ReferralWitness {
  merchant: string;
  referrer: string;
  /** Referrer share in atomic units (decimal string), == floor(amount*bps/10000). */
  referrerAmount: string;
  /** Earliest settlement timestamp (unix seconds). */
  validAfter: number;
  /** The on-chain `bytes32` attribution id: keccak256(utf8(rawAttributionId)). */
  attributionId: Hex;
}

/**
 * Hash an off-chain attribution id string to the `bytes32` value used on-chain.
 *
 * @param attributionId - The off-chain attribution id string.
 * @returns The keccak256 of its UTF-8 bytes, as a 0x-prefixed 32-byte hex string.
 */
export function hashAttributionId(attributionId: string): Hex {
  return keccak256(toBytes(attributionId));
}

/**
 * Build the witness for a payment, deriving `referrerAmount` from the advertised
 * `splitBps` so the signed value and the advertised terms agree by construction.
 * The `attributionId` is hashed to `bytes32` to match the on-chain witness type.
 *
 * @param params - The payment and referral parameters.
 * @param params.merchant - Merchant recipient address.
 * @param params.referrer - Referrer recipient address.
 * @param params.amount - Total payment in atomic units (decimal string or bigint).
 * @param params.splitBps - Referrer share in basis points (1..10000).
 * @param params.attributionId - Off-chain conversion id; hashed into the witness.
 * @param params.validAfter - Earliest settlement timestamp (unix seconds); defaults to 0.
 * @returns The witness values the payer signs and the contract verifies.
 */
export function buildReferralWitness(params: {
  merchant: string;
  referrer: string;
  amount: string | bigint;
  splitBps: number;
  attributionId: string;
  validAfter?: number;
}): ReferralWitness {
  const { referrerAmount } = computeReferralSplit(params.amount, params.splitBps);
  if (referrerAmount === "0") {
    throw new ReferralSplitError(
      "computed referrerAmount is 0 (amount too small for splitBps); the splitter would revert",
    );
  }
  return {
    merchant: params.merchant,
    referrer: params.referrer,
    referrerAmount,
    validAfter: params.validAfter ?? 0,
    attributionId: hashAttributionId(params.attributionId),
  };
}

/**
 * Build the EIP-712 typed data for a Permit2 `PermitWitnessTransferFrom` that the
 * payer signs to authorize a referral settlement. Pass the result to a viem
 * `signTypedData` call; the resulting signature goes to
 * `X402ReferralSplitProxy.settle`. `spender` MUST be the splitter contract.
 *
 * @param params - Permit2 + witness parameters.
 * @param params.chainId - EVM chain id of the splitter deployment.
 * @param params.splitter - The X402ReferralSplitProxy address (Permit2 spender).
 * @param params.token - ERC-20 being paid.
 * @param params.amount - Total payment in atomic units.
 * @param params.nonce - Permit2 unordered nonce.
 * @param params.deadline - Permit2 signature deadline (unix seconds).
 * @param params.witness - The referral witness (from `buildReferralWitness`).
 * @param params.permit2 - Optional Permit2 address override (defaults to canonical).
 * @returns A viem-compatible typed-data object for `signTypedData`.
 */
export function buildReferralPermit2TypedData(params: {
  chainId: number;
  splitter: string;
  token: string;
  amount: string | bigint;
  nonce: string | bigint;
  deadline: number | bigint;
  witness: ReferralWitness;
  permit2?: string;
}) {
  const w = params.witness;
  return {
    domain: {
      name: "Permit2",
      chainId: params.chainId,
      verifyingContract: (params.permit2 ?? PERMIT2_ADDRESS) as Hex,
    },
    types: PERMIT2_WITNESS_TYPES,
    primaryType: "PermitWitnessTransferFrom" as const,
    message: {
      permitted: { token: params.token as Hex, amount: BigInt(params.amount) },
      spender: params.splitter as Hex,
      nonce: BigInt(params.nonce),
      deadline: BigInt(params.deadline),
      witness: {
        merchant: w.merchant as Hex,
        referrer: w.referrer as Hex,
        referrerAmount: BigInt(w.referrerAmount),
        validAfter: BigInt(w.validAfter),
        attributionId: w.attributionId,
      },
    },
  };
}
