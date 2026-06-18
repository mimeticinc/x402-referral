/**
 * End-to-end protocol demo for the referral-split extension (off-chain layer).
 *
 * Shows how the three roles use @x402/extensions:
 *   1. resource server advertises referral terms in its 402 response
 *   2. payer reads the terms and builds the Permit2 witness it will sign
 *   3. facilitator verifies the signed witness binds exactly the advertised terms
 *
 * The actual on-chain settlement is demonstrated by the Foundry script
 * contracts/evm/script/DemoReferralSettlement.s.sol.
 *
 * Run: cd typescript/packages/extensions && npx tsx examples/referral-split-demo.ts
 */

import {
  declareReferralSplitExtension,
  extractReferralSplitInfo,
  computeReferralSplit,
  buildReferralWitness,
  referralWitnessMatchesTerms,
  WITNESS_TYPE_STRING,
  type ReferralSplitInfo,
} from "../src/referral-split/index";

const MERCHANT = "0x00655EA989254C13e93C5a1F74C4636b5B9926B5";
const REFERRER = "0xbbD0F905B1ab8868f461976C520e518A623C0100";
const SPLITTER = "0x4AdE44726d54346A8d1899fcFa1aa20FC867F2af"; // live X402ReferralSplitProxy on Base Sepolia
const AMOUNT = "100000000"; // 100 USDC (6dp)

const log = (title: string, value: unknown): void => {
  console.log(`\n${title}`);
  console.log(typeof value === "string" ? value : JSON.stringify(value, null, 2));
};

// 1) Resource server advertises referral terms in its 402 Payment Required.
const terms: ReferralSplitInfo = {
  merchant: MERCHANT,
  referrer: REFERRER,
  splitBps: 2000, // 20%
  attributionId: "att_demo_0001",
  splitter: SPLITTER,
  network: "eip155:84532", // Base Sepolia
};
const paymentRequired = {
  accepts: [
    { scheme: "exact", network: "eip155:84532", payTo: SPLITTER, maxAmountRequired: AMOUNT },
  ],
  extensions: declareReferralSplitExtension(terms),
};
log("1) Server → 402 Payment Required (extensions['referral-split'])", paymentRequired.extensions);

// 2) Payer reads the advertised terms and computes/builds the witness to sign.
const advertised = extractReferralSplitInfo(paymentRequired);
if (!advertised) throw new Error("no referral terms advertised");
const split = computeReferralSplit(AMOUNT, advertised.splitBps);
log("2a) Payer computes the split", split);

const witness = buildReferralWitness({
  merchant: MERCHANT,
  referrer: advertised.referrer,
  amount: AMOUNT,
  splitBps: advertised.splitBps,
  attributionId: advertised.attributionId,
});
log("2b) Payer builds the Permit2 witness it will sign", witness);
log("    EIP-712 witness type the payer signs over", WITNESS_TYPE_STRING);

// 3) Facilitator verifies the (signed) witness binds exactly the advertised terms.
const ok = referralWitnessMatchesTerms(advertised, AMOUNT, witness);
log("3a) Facilitator verifies the honest witness", ok);
if (!ok) throw new Error("honest witness should verify");

// A tampered witness (attacker redirects the merchant share) must be rejected.
const tampered = { ...witness, merchant: REFERRER };
log(
  "3b) Facilitator rejects a tampered witness (merchant redirected)",
  referralWitnessMatchesTerms(advertised, AMOUNT, tampered),
);

console.log(
  "\n✓ off-chain flow complete — payer would sign `witness`, facilitator settles via X402ReferralSplitProxy.settle()",
);
console.log("  on-chain settlement demo: contracts/evm/script/DemoReferralSettlement.s.sol");
