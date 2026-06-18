/**
 * Tests for the Referral-Split Extension
 */

import { describe, it, expect } from "vitest";
import { hashTypedData } from "viem";
import {
  REFERRAL_SPLIT,
  computeReferralSplit,
  ReferralSplitError,
  declareReferralSplitExtension,
  validateReferralSplitInfo,
  extractReferralSplitInfo,
  referralTermsMatch,
  referralWitnessMatchesTerms,
  buildReferralWitness,
  buildReferralPermit2TypedData,
  hashAttributionId,
  PERMIT2_WITNESS_TYPES,
  WITNESS_TYPE,
  type ReferralSplitInfo,
} from "../src/referral-split/index";

const REFERRER = "0x1111111111111111111111111111111111111111";
const SPLITTER = "0x2222222222222222222222222222222222222222";
const MERCHANT = "0x3333333333333333333333333333333333333333";

const baseInfo = (overrides: Partial<ReferralSplitInfo> = {}): ReferralSplitInfo => {
  return {
    merchant: MERCHANT,
    referrer: REFERRER,
    splitBps: 2000,
    attributionId: "att_abc123",
    splitter: SPLITTER,
    network: "eip155:84532",
    ...overrides,
  };
};

describe("computeReferralSplit", () => {
  it("splits a round amount by basis points", () => {
    const split = computeReferralSplit("1000000", 2000); // 20% of 1 USDC (6dp)
    expect(split.referrerAmount).toBe("200000");
    expect(split.merchantAmount).toBe("800000");
    expect(split.totalAmount).toBe("1000000");
  });

  it("floors the referrer cut so totals never over-distribute", () => {
    const split = computeReferralSplit("1001", 2000); // 20% of 1001 = 200.2
    expect(split.referrerAmount).toBe("200"); // floored
    expect(split.merchantAmount).toBe("801"); // remainder
    expect(BigInt(split.referrerAmount) + BigInt(split.merchantAmount)).toBe(1001n);
  });

  it("handles large bigint-scale amounts without precision loss", () => {
    const amount = "123456789012345678901234567890";
    const split = computeReferralSplit(amount, 750); // 7.5%
    expect(BigInt(split.referrerAmount) + BigInt(split.merchantAmount)).toBe(BigInt(amount));
    expect(split.referrerAmount).toBe(((BigInt(amount) * 750n) / 10000n).toString());
  });

  it("supports 100% to referrer (10000 bps)", () => {
    const split = computeReferralSplit("500", 10000);
    expect(split.referrerAmount).toBe("500");
    expect(split.merchantAmount).toBe("0");
  });

  it("rejects out-of-range and non-integer bps", () => {
    expect(() => computeReferralSplit("1000", 0)).toThrow(ReferralSplitError);
    expect(() => computeReferralSplit("1000", 10001)).toThrow(ReferralSplitError);
    expect(() => computeReferralSplit("1000", 12.5)).toThrow(ReferralSplitError);
  });

  it("rejects non-positive or malformed amounts", () => {
    expect(() => computeReferralSplit("0", 2000)).toThrow(ReferralSplitError);
    expect(() => computeReferralSplit("-5", 2000)).toThrow(ReferralSplitError);
    expect(() => computeReferralSplit("not-a-number", 2000)).toThrow(ReferralSplitError);
  });
});

describe("declareReferralSplitExtension", () => {
  it("produces a PaymentRequired extension entry under the right key", () => {
    const ext = declareReferralSplitExtension(baseInfo());
    expect(ext[REFERRAL_SPLIT]).toBeDefined();
    expect(ext[REFERRAL_SPLIT].info.referrer).toBe(REFERRER);
    expect(ext[REFERRAL_SPLIT].info.required).toBe(false);
    expect(ext[REFERRAL_SPLIT].schema.required).toContain("attributionId");
  });

  it("requires splitter and network server-side", () => {
    expect(() => declareReferralSplitExtension(baseInfo({ splitter: undefined }))).toThrow(
      ReferralSplitError,
    );
    expect(() => declareReferralSplitExtension(baseInfo({ network: undefined }))).toThrow(
      ReferralSplitError,
    );
  });

  it("rejects a malformed referrer address", () => {
    expect(() => validateReferralSplitInfo(baseInfo({ referrer: "0xdead" }))).toThrow(
      ReferralSplitError,
    );
  });
});

describe("extractReferralSplitInfo / referralTermsMatch", () => {
  it("round-trips advertised terms through a PaymentRequired-shaped message", () => {
    const message = { extensions: declareReferralSplitExtension(baseInfo()) };
    const extracted = extractReferralSplitInfo(message);
    expect(extracted?.attributionId).toBe("att_abc123");
  });

  it("returns null when the extension is absent or malformed", () => {
    expect(extractReferralSplitInfo({ extensions: {} })).toBeNull();
    expect(extractReferralSplitInfo(undefined)).toBeNull();
    expect(extractReferralSplitInfo({ extensions: { [REFERRAL_SPLIT]: { info: {} } } })).toBeNull();
  });

  it("matches terms case-insensitively on the referrer address", () => {
    const advertised = baseInfo();
    const echoed = baseInfo({ referrer: REFERRER.toUpperCase().replace("0X", "0x") });
    expect(referralTermsMatch(advertised, echoed)).toBe(true);
    expect(referralTermsMatch(advertised, baseInfo({ splitBps: 1000 }))).toBe(false);
  });
});

describe("buildReferralWitness", () => {
  it("derives referrerAmount from splitBps and hashes attributionId to bytes32", () => {
    const witness = buildReferralWitness({
      merchant: MERCHANT,
      referrer: REFERRER,
      amount: "1000000",
      splitBps: 2000,
      attributionId: "att_abc123",
    });
    expect(witness.referrerAmount).toBe("200000");
    expect(witness.merchant).toBe(MERCHANT);
    expect(witness.validAfter).toBe(0);
    // attributionId is the keccak256 of the raw id (0x + 64 hex chars)
    expect(witness.attributionId).toBe(hashAttributionId("att_abc123"));
    expect(witness.attributionId).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("throws when the computed referrer amount floors to zero", () => {
    expect(() =>
      buildReferralWitness({
        merchant: MERCHANT,
        referrer: REFERRER,
        amount: "1", // 0.01% of 1 floors to 0
        splitBps: 1,
        attributionId: "att_abc123",
      }),
    ).toThrow(ReferralSplitError);
  });
});

describe("referralWitnessMatchesTerms", () => {
  it("accepts a witness that binds exactly the advertised terms", () => {
    const advertised = baseInfo();
    const witness = buildReferralWitness({
      merchant: MERCHANT,
      referrer: REFERRER,
      amount: "1000000",
      splitBps: advertised.splitBps,
      attributionId: advertised.attributionId,
    });
    expect(referralWitnessMatchesTerms(advertised, "1000000", witness)).toBe(true);
  });

  it("rejects a witness with a tampered referrer, merchant, amount, or attribution", () => {
    const advertised = baseInfo();
    const good = buildReferralWitness({
      merchant: MERCHANT,
      referrer: REFERRER,
      amount: "1000000",
      splitBps: advertised.splitBps,
      attributionId: advertised.attributionId,
    });
    // tampered referrer
    expect(
      referralWitnessMatchesTerms(advertised, "1000000", { ...good, referrer: SPLITTER }),
    ).toBe(false);
    // tampered merchant
    expect(
      referralWitnessMatchesTerms(advertised, "1000000", { ...good, merchant: SPLITTER }),
    ).toBe(false);
    // different total amount changes the expected referrerAmount
    expect(referralWitnessMatchesTerms(advertised, "2000000", good)).toBe(false);
    // tampered attribution hash
    expect(
      referralWitnessMatchesTerms(advertised, "1000000", {
        ...good,
        attributionId: hashAttributionId("other"),
      }),
    ).toBe(false);
  });
});

describe("validateReferralSplitInfo — on-chain guard parity", () => {
  const ZERO = "0x0000000000000000000000000000000000000000";

  it("rejects the zero address for referrer or merchant", () => {
    expect(() => validateReferralSplitInfo(baseInfo({ referrer: ZERO }))).toThrow(
      ReferralSplitError,
    );
    expect(() => validateReferralSplitInfo(baseInfo({ merchant: ZERO }))).toThrow(
      ReferralSplitError,
    );
  });

  it("rejects merchant == referrer (DuplicateRecipient on-chain)", () => {
    expect(() => validateReferralSplitInfo(baseInfo({ merchant: REFERRER }))).toThrow(
      ReferralSplitError,
    );
  });

  it("rejects merchant/referrer == splitter (SelfRecipient on-chain)", () => {
    expect(() => validateReferralSplitInfo(baseInfo({ merchant: SPLITTER }))).toThrow(
      ReferralSplitError,
    );
    expect(() => validateReferralSplitInfo(baseInfo({ referrer: SPLITTER }))).toThrow(
      ReferralSplitError,
    );
  });
});

describe("buildReferralPermit2TypedData", () => {
  it("Witness type definition matches the Solidity WITNESS_TYPE string", () => {
    const derived = `Witness(${PERMIT2_WITNESS_TYPES.Witness.map(f => `${f.type} ${f.name}`).join(",")})`;
    expect(derived).toBe(WITNESS_TYPE);
  });

  it("produces signable EIP-712 typed data with the bound witness", () => {
    const witness = buildReferralWitness({
      merchant: MERCHANT,
      referrer: REFERRER,
      amount: "1000000",
      splitBps: 2000,
      attributionId: "att_abc123",
    });
    const typed = buildReferralPermit2TypedData({
      chainId: 84532,
      splitter: SPLITTER,
      token: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
      amount: "1000000",
      nonce: "1",
      deadline: 9999999999,
      witness,
    });
    expect(typed.primaryType).toBe("PermitWitnessTransferFrom");
    expect(typed.message.spender).toBe(SPLITTER);
    expect(typed.message.witness.referrerAmount).toBe(200000n);
    // viem can hash it → a valid EIP-712 digest (proves the types/message are well-formed)
    expect(hashTypedData(typed)).toMatch(/^0x[0-9a-f]{64}$/);
  });
});
