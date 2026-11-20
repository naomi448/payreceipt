# 🧾 PayReceipt — invoice payments with exact amounts and verifiable on-chain receipts

**Aevum Builder Challenge #1 · Track: Invoice Payments (with Confirmation of Payee)**
**Network: Aevum testnet (chain ID 44005) · Settlement token: tUSD8**

PayReceipt lets a merchant create an invoice for an **exact** amount of tUSD8
payable to a **named** payee. A payer pays it **exactly once**; the contract
pulls precisely the invoiced amount from the payer to the payee and emits an
`InvoicePaid` event — a permanent, publicly verifiable **on-chain receipt**.

> Testnet demo. tUSD8/tQDAY on Aevum testnet have no real-world value.

---

## The problem

Small merchants and freelancers who bill in stablecoins today usually just
paste a wallet address into a chat message and say "send 250 here". That flow
has no shared source of truth:

- **Wrong amounts happen** — over- and under-payment are both possible, and
  neither side can prove what was agreed.
- **Wrong recipients happen** — a bare address gives the payer no way to check
  *who* they are paying (the problem Confirmation of Payee solves in banking).
- **No receipt exists** — "did you pay?" is answered with screenshots, not
  with something anyone can independently verify.
- **Double payment is possible** — nothing stops a payer (or a buggy client)
  from paying the same request twice.

## How PayReceipt fixes it

| Property | How |
|---|---|
| Exact-amount enforcement | Every payment is keyed to an `invoiceId` and moves **exactly** `invoice.amount` — never more, never less. A 1-wei "payment" against a 250 tUSD8 invoice is impossible. |
| Idempotency | A one-way state machine (`Open → Paid / Cancelled`, `Paid → Refunded`). A paid invoice **can never be paid again**; retries and double-clicks revert safely instead of moving money twice. |
| Confirmation of Payee | The payee's human-readable name is stored on-chain at invoice creation. The UI shows the name and exact amount and asks the payer to verify **before** approving anything. |
| Verifiable receipt | Payment emits `InvoicePaid(invoiceId, payer, payee, amount, paidAt)` and records payer + timestamp in state. Anyone can check the receipt in the UI or on the explorer — no screenshots needed. |
| Refund path | The merchant can refund a paid invoice in full to the **original payer**; the invoice then locks in `Refunded`. |
| Expiry | Invoices carry an expiry timestamp. Expired invoices can't be paid; expiry is computed at read time, so no keeper or extra transaction is needed. |
| No admin powers | No owner, no pause, no upgrades, no fee skim. Nobody — including the author — can move funds outside the create → pay / cancel / refund flows. |

## How it differs from the starter kit's `Checkout.sol`

The official Aevum starter kit's checkout example processes a payment for a
caller-supplied amount that is **not tied to any invoice**: whoever calls it
decides how much moves, there is no agreed amount to enforce, no payee name to
confirm, no per-request state, and nothing prevents paying the same request
twice. PayReceipt is written from scratch around the opposite model:

1. **Payments are keyed to an invoice** with a merchant-agreed, contract-enforced exact amount.
2. **A strict, idempotent state machine** makes double payment and double refund impossible by construction.
3. **Receipts are first-class**: a dedicated event + stored payer/timestamp, designed to be checked by third parties.
4. **Confirmation of Payee** is built into the data model (`payeeName`) and into the UI flow (verify-then-pay).
5. **A refund path** returns funds to the original payer, which a plain checkout cannot express.

## Architecture

```
┌────────────────┐   createInvoice(payee, name, amount, memo, expiry)
│    Merchant    │ ───────────────────────────────┐
└────────────────┘                                ▼
                                        ┌──────────────────┐
┌────────────────┐   getInvoice(id)     │   PayReceipt     │      transferFrom
│     Payer      │ ────── verify ─────► │  (this contract) │ ──────────────────►  payee
│                │   approve + pay      │  state machine:  │      (exact amount)
└────────────────┘ ───────────────────► │  Open→Paid→Ref.  │
                                        └──────────────────┘
┌────────────────┐   getInvoice(id)           │ InvoicePaid = receipt
│  Anyone        │ ────── verify receipt ─────┘ (event + stored payer/paidAt)
└────────────────┘
```

- **`src/PayReceipt.sol`** — the whole protocol in one small, dependency-free
  contract. Hand-written minimal ERC-20 interface with return-value checks,
  checks-effects-interactions, and a hand-rolled reentrancy guard.
- **`web/index.html`** — a single static page (vanilla JS + ethers v6 via CDN):
  connect wallet (auto-switches to chain 44005), create invoice, look up &
  verify an invoice (payee name + exact amount shown *before* payment),
  approve + pay, merchant cancel/refund, and a receipt view with explorer links.
  Hostable anywhere static (e.g. GitHub Pages), same pattern as a typical
  testnet demo front-end.
- **`test/`** — Foundry tests with a mock 6-decimal tUSD8, covering exact
  payment + receipt event, double-payment revert, pay-after-cancel,
  pay-after-expiry (incl. the inclusive expiry boundary), non-merchant
  cancel/refund reverts, refund correctness and invoice locking, and all
  creation validation. The suite is dependency-free (hand-rolled cheatcode
  interface), so `forge test` works fully offline.

## Contract API (summary)

- `createInvoice(payee, payeeName, amount, memo, expiry) → invoiceId`
  Amount must be > 0, expiry must be in the future. Creator becomes the merchant.
- `payInvoice(invoiceId)` — payer must first `approve` this contract for the
  exact amount on tUSD8. Reverts unless the invoice is Open and unexpired.
- `cancelInvoice(invoiceId)` — merchant only, Open only.
- `refundInvoice(invoiceId)` — merchant only, Paid only; merchant approves the
  contract to pull the amount back to the original payer.
- `getInvoice(invoiceId)` — all fields plus a live-computed `expired` flag.
- `isPayable(invoiceId)`, `invoiceCount()`.

## Build & test locally

Requirements: [Foundry](https://book.getfoundry.sh/) (forge 1.x).

```bash
forge build
forge test        # 16 tests, all passing — see BUILD-LOG.txt
```

`foundry.toml` pins `evm_version = "shanghai"` and solc 0.8.26 — Aevum's EVM
is Shanghai, so Cancun opcodes must never be emitted.

## Deployment (Aevum testnet)

> **Status: not yet deployed — fields below are filled in at deployment time.**

| Item | Value |
|---|---|
| PayReceipt contract | `0xb5b3F54E5D4D8e2783F1eD5E6f9f64c2749A5C17` |
| Explorer | https://explorer-test.qday.info/address/0xb5b3F54E5D4D8e2783F1eD5E6f9f64c2749A5C17 |
| Deployed from commit | `18d38aff44aa9901bc04fafa187b7314e069f1b6` |
| tUSD8 (fixed) | `0x456569838f1d43009A91ebA4263147Afd7233483` |
| Live demo UI | https://rainbow-gecko-9ba734.netlify.app (interim host; canonical demo ships with this repo) |

Sample end-to-end transactions (create → pay → receipt):

| Step | Tx hash |
|---|---|
| createInvoice | `0x4e0130dcf7b5a37cfe47e058f09649de5750721165a4f59002e8354de692e696` |
| approve (payer) | `0xbbf565abc062884b50d85ace4872f351b8ec5bde98d4c3578ff7b51c7ad66854` |
| payInvoice | `0xaa2edd37c71e3fa3e0e046c6464bd3279809c32011973b2f8e4dfef20da35801` |

Deploy sketch (the deployer wallet is a dedicated testnet wallet funded from
the QDay Discord faucet with 1 tQDAY + 5 tUSD8):

```bash
forge create src/PayReceipt.sol:PayReceipt \
  --rpc-url https://rpc-test.qday.info \
  --constructor-args 0x456569838f1d43009A91ebA4263147Afd7233483 \
  --private-key <DEPLOYER_TESTNET_KEY>   # dedicated testnet wallet only
```

Then set `CONFIG.contractAddress` in `web/index.html` to the deployed address.
Note: per the official starter-kit docs, contract verification on the Aevum
explorer is not available yet, so this README's contract address + exact
commit link serve as the source-of-truth reference for the deployed code.

## Roadmap

- Gasless payment via tUSD8's EIP-3009 signed transfers + a relayer (the token
  already supports it), so payers need no tQDAY for gas.
- Optional partial payments with a running total, for installment invoices.
- A merchant dashboard listing invoices by merchant/payee (chunked log scans).
- Mainnet version when QDay mainnet launches.

## Credits

- Built for the **Aevum Builder Challenge #1** (QDay / Aevum) on DoraHacks.
- Network facts, faucet flow, and the `Checkout.sol` comparison point come from
  the official **Aevum starter kit** by PQA Labs —
  https://github.com/qday-io/aevum-starter-kit — licensed under the **MIT
  License** (© PQA Labs). PayReceipt's contract and UI are original code
  written for this challenge; no starter-kit code is copied.
- Token: tUSD8 test stablecoin on Aevum testnet.

## License

MIT — see [LICENSE](./LICENSE). Copyright (c) 2026 listy.
