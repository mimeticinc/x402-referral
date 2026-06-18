# Extension: `referral-split`

## Summary

The `referral-split` extension lets a resource server attribute a payment to a
**referrer** (an affiliate, marketplace, or discovery agent) and have the
referrer's commission settled **atomically and on-chain** as part of the same
x402 payment — with no separate, trusted payout step.

A resource server advertises, in its `402 Payment Required` response, that a
share of the payment is owed to a referrer. Instead of paying the merchant
directly, the payer signs a Permit2 *witness* that routes the payment through a
**referral splitter** contract, which transfers the merchant's share to the
merchant and the referrer's share to the referrer in one transaction, emitting a
`ReferralSettled` event.

Because the split parameters are bound into the payer's signature (the witness),
the facilitator **cannot** redirect funds or alter the split. The settlement
transaction itself is the proof that the referrer was paid — this is what makes
affiliate attribution *provable* rather than merely *recorded*.

## Use Cases

- **Affiliate programs (Rewardful-style), settled on-chain.** A merchant runs an
  affiliate program; when an affiliate's link drives an x402 purchase, the
  affiliate's commission is paid in the same transaction as the sale.
- **Agentic commerce.** When an AI agent buys a resource it discovered through a
  catalog/marketplace, the discovery surface is the referrer and is paid
  provably per conversion.
- **Provable payouts.** Any integrator that needs an auditable, third-party
  verifiable record that a commission was paid for a specific conversion.

## Relationship to other extensions

- Composes with [`offer-receipt`](./extension-offer-and-receipt.md): the signed
  offer proves the referral terms originated from the resource server; the
  on-chain `ReferralSettled` event proves they were honored.
- Composes with [`payment-identifier`](./payment_identifier.md): the
  `attributionId` MAY equal the payment identifier for end-to-end idempotency.

---

## `PaymentRequired`

The resource server advertises the referral terms. `payTo` in the corresponding
`accepts` object MUST be the referral splitter contract address.

```json
{
  "extensions": {
    "referral-split": {
      "info": {
        "required": true,
        "merchant": "0xMERCHANT...",
        "referrer": "0xREFERRER...",
        "splitBps": 2000,
        "attributionId": "att_7d5d747be160e280504c099d984bcfe0",
        "splitter": "0xSPLITTER...",
        "network": "eip155:84532"
      },
      "schema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "properties": {
          "required": { "type": "boolean" },
          "merchant": { "type": "string", "pattern": "^0x[a-fA-F0-9]{40}$" },
          "referrer": { "type": "string", "pattern": "^0x[a-fA-F0-9]{40}$" },
          "splitBps": { "type": "integer", "minimum": 1, "maximum": 10000 },
          "attributionId": { "type": "string", "minLength": 1, "maxLength": 128 },
          "splitter": { "type": "string", "pattern": "^0x[a-fA-F0-9]{40}$" },
          "network": { "type": "string" }
        },
        "required": ["merchant", "referrer", "splitBps", "attributionId", "splitter", "network"]
      }
    }
  }
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `merchant` | address | The authenticated merchant recipient (the real payee). Bound into the witness; the facilitator MUST verify the signed witness `merchant` equals this advertised value. |
| `referrer` | address | Recipient of the commission. |
| `splitBps` | integer (1–10000) | Referrer's share in basis points (2000 = 20%). |
| `attributionId` | string | Stable id binding this payment to a conversion in the merchant's affiliate ledger. Hashed to `bytes32` on-chain (`keccak256(utf8(attributionId))`). |
| `splitter` | address | The `X402ReferralSplitProxy` contract that performs the split. |
| `network` | string (CAIP-2) | Chain the splitter is deployed on, e.g. `eip155:84532` (Base Sepolia), `eip155:8453` (Base). |
| `required` | boolean | If `true`, the payer MUST route through the splitter; a direct `payTo` is not accepted. Default `false`. |

---

## `PaymentPayload`

The payer echoes the extension to acknowledge the terms it signed over. The
authoritative binding is the Permit2 witness (see Settlement); the echo is for
observability only and is **not** authenticated. The echo omits `merchant` — the
merchant is authenticated by the signed witness, not the echo, so verifiers MUST
NOT rely on an echoed merchant.

```json
{
  "extensions": {
    "referral-split": {
      "info": {
        "referrer": "0xREFERRER...",
        "splitBps": 2000,
        "attributionId": "att_7d5d747be160e280504c099d984bcfe0"
      }
    }
  }
}
```

---

## Settlement

The split is enforced by the `X402ReferralSplitProxy` contract using Permit2's
`permitWitnessTransferFrom`. The witness binds the split so the payer's
signature authorizes *exactly* this distribution:

```
Witness(address merchant,address referrer,uint256 referrerAmount,uint256 validAfter,bytes32 attributionId)
```

1. The payer signs a Permit2 permit for `amount` of `asset`, with the witness
   above, naming the splitter as the spender.
2. The facilitator calls `splitter.settle(permit, owner, witness, signature)`.
3. The splitter pulls `amount` to itself, then transfers `referrerAmount` to
   `referrer` and `amount - referrerAmount` to `merchant`.
4. It emits:

```
event ReferralSettled(
    bytes32 indexed attributionId,
    address indexed merchant,
    address indexed referrer,
    address token,
    uint256 merchantAmount,
    uint256 referrerAmount,
    address payer
);
```

`referrerAmount` is computed off-chain as `floor(amount * splitBps / 10000)` and
included in the witness, so the on-chain split and the advertised `splitBps`
agree by construction (any mismatch invalidates the signature). `attributionId`
in the witness is `keccak256(utf8(advertised attributionId))`.

### Facilitator / resource-server verification (REQUIRED)

The echoed `PaymentPayload` extension fields are **not** authenticated — only the
Permit2 witness the payer signed is. Before settling (and before delivering the resource), the facilitator/resource
server MUST do **both** of:

1. **Verify the Permit2 authorization itself** (via the standard x402 Permit2
   verification path): the signature is valid, `spender == splitter`,
   `token == asset`, the signed `amount`, `deadline`, and `validAfter`.
2. **Verify the witness binds the advertised terms** (`referralWitnessMatchesTerms`):
   - `witness.merchant == advertised.merchant` (the server's own authenticated payee),
   - `witness.referrer == advertised.referrer`,
   - `witness.referrerAmount == floor(amount * advertised.splitBps / 10000)`,
   - `witness.attributionId == keccak256(utf8(advertised.attributionId))`.

Step 2 alone is necessary but not sufficient — without step 1 the signature/authorization
is unchecked; without the `merchant` check in step 2 a payer could sign a different
payee. Reject the settlement on any mismatch.

### Validity rules (enforced on-chain)

- `merchant != 0`, `referrer != 0`, `amount != 0`.
- `merchant` and `referrer` MUST NOT be the splitter contract (funds would be stuck).
- `merchant != referrer` (distinct recipients).
- `0 < referrerAmount <= amount`. Because `referrerAmount` is floored, terms where
  `floor(amount * splitBps / 10000) == 0` (amount too small for the rate) are
  invalid and revert; clients MUST NOT build such witnesses.
- **Exact receipt enforced.** The splitter checks recipient balance deltas and
  reverts unless each recipient receives precisely its signed amount, so the
  emitted `ReferralSettled` amounts are always truthful (fee-on-transfer / rebasing
  tokens cause a revert rather than a silent shortfall).

### Trust properties

- **No fund redirection.** Merchant, referrer, and amounts are in the signed
  witness; the facilitator cannot change them.
- **No operator omission.** The referrer is paid in the same transaction as the
  merchant; there is no later payout the operator could skip.
- **Publicly verifiable.** `ReferralSettled` is the proof of payment for
  `attributionId`; anyone can verify it without trusting the merchant or
  facilitator.

### Non-goals / caveats

- **Irreversibility.** On-chain settlement cannot be clawed back. This extension
  is appropriate for non-refundable / agentic payments. For refundable commerce,
  use a hold-then-payout model off-chain (e.g. Stripe Connect) and reconcile.
- **Refund handling** (if the underlying sale is refunded) is out of scope here;
  it must be modeled by the integrating affiliate ledger as separate debt.
- **Sanctions/compliance.** Integrators are responsible for screening `referrer`
  addresses (e.g. OFAC) before advertising terms.
