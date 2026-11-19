# tUSD8 Freelance Pay

A mini freelance marketplace where payment is escrowed in a smart contract —
the client can't run off without paying, and the freelancer can't get paid
without delivering.

Built for the **Aevum Builder Challenge #1** on QDay: one working payment flow
with **tUSD8** on the **QDay Aevum testnet** (chain ID 44005).

**Live demo: https://iamyerhyer.github.io/tusd8-freelance-pay/** — browse all
jobs read-only, or connect a wallet on the Aevum testnet to act: the UI shows
each wallet only its own actions for each job state, and explains on-screen
why a refund is locked whenever the guard blocks one.

## The flow

1. **Client creates a job** — title, description, amount in tUSD8, deadline,
   and the freelancer's wallet address.
2. **Freelancer accepts** the agreement.
3. **Client deposits** the tUSD8 into the escrow contract. Funds are locked,
   visible to both sides.
4. **Freelancer delivers** — marks the job complete and attaches a deliverable
   link/hash as proof.
5. **Client releases** — the contract sends the tUSD8 to the freelancer.
6. **Refund path** — guarded, see below.

States: `Created → Accepted → Funded → Delivered → Released`, with `Refunded`
as the exit state. Every transition is an on-chain transaction with an event,
so the whole story is readable on the explorer.

## The refund guard

A naive escrow lets the client refund at any time — including after receiving
the work. That breaks the trust the product is selling, so:

- **Created / Accepted** (nothing deposited): the client can cancel freely.
- **Funded, freelancer never delivers**: refund unlocks only after the job
  deadline passes — a freelancer can't hold money hostage by going silent,
  and a client can't yank funding mid-job.
- **Delivered**: refund stays locked until **both** the deadline **and** a
  3-day review window after delivery have passed. Taking the work and
  clawing the money back is not possible inside the window.

Dispute arbitration is deliberately out of scope — it is the named production
next step.

## Contracts

| Contract | Address |
|---|---|
| FreelanceEscrow | `0x07310bcba28550d429f1d7d779f47e049f468b0e` |
| tUSD8 (official, QDay Aevum) | `0x456569838f1d43009A91ebA4263147Afd7233483` |

- Network: QDay Aevum testnet, chain ID `44005`
- RPC: `https://rpc-test.qday.info`
- Explorer: https://explorer-test.qday.info/address/0x07310bcba28550d429f1d7d779f47e049f468b0e
- Deploy tx: `0x9ece21c6ef28a27db8cb2ce71523120419dd467383984a590ca8ec9e746d4b56`
- Source: **verified** on the explorer (contract name `FreelanceEscrow`)

## Live end-to-end run (18 Nov 2026)

The deployed contract has already run the full flow once on Aevum with real
testnet tUSD8 (job #0, 5 tUSD8, "Logo design"):

| Step | Tx |
|---|---|
| Create | `0xd2b07c6c194c2884ef73360d8ffb09ff29dfecd38c6704155a07436ecb01c032` |
| Accept | `0x52610a2cc7ba7614cbcc557de8252afe0cd2d07c3c01396b648a248f33f9890d` |
| Approve + Deposit | `0x7b9c464f401b7395b31400b11901ab9c44d125def5d20128a4e7b9212b572626` · `0x938c86a424f1525dd3c7a5e99e3887d36975ad0fa9a8b416aa07da3bb8b2a9b0` |
| Deliver | `0xe7d9d3398c910796d72229441ca80d66b9214f0314bc017c81df327df9f4d044` |
| Release | `0xac592980c238bcfe4ef9f95bdc598b62ee20a961f516283918fd390b8c7d37e3` |

Result: escrow held the 5 tUSD8 mid-flow, freelancer received the full 5 tUSD8
on release, escrow returned to zero.

`src/MockTUSD8.sol` is a minimal 6-decimal ERC-20 used **only** for local
tests; on Aevum the escrow points at the real tUSD8 contract above.

## Development

Foundry project (Solidity 0.8.20):

```bash
forge build
forge test   # 11 tests covering the full spec checklist
```

Test coverage: happy path end-to-end · cancel before funding · funded refund
locked before the deadline · refund after deadline when never delivered ·
delivered refund locked inside the review window · delivered refund after
deadline + review window · wrong-wallet calls rejected at every step ·
double-deposit and double-release impossible · zero-amount and invalid
terms rejected · deposit without token approval fails.

## Roadmap inside this challenge

- [x] Escrow contract + tests, deployed on Aevum testnet, source verified
- [x] Front end: job list, create job, job detail with state-aware actions
      (live at the demo link above)
- [ ] Payout options (after release): convert to other stablecoins, withdraw
      as crypto, or withdraw to local currency at a transparent quoted rate
      (bank settlement via a licensed partner in production; labelled as a
      simulation on testnet)

Testnet tokens only — nothing here has monetary value.
