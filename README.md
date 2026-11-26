# tUSD8 Freelance Pay

A remote-work board in Web3 settings, paid in **tUSD8**: clients post jobs with a pay-per-spot and a limited number
of spots and fund the full budget into a smart contract up front, so every
spot on the board is real, paid-for work. Freelancers apply, the client
approves the qualified ones, they deliver, and the contract pays them. First
come, first served — spots are scarce by design.

Built for the **Aevum Builder Challenge #1** on QDay: one working payment flow
with **tUSD8** on the **QDay Aevum testnet** (chain ID 44005).

**Live demo: https://iamyerhyer.github.io/tusd8-freelance-pay/** — browse the
board read-only, or connect a wallet on the Aevum testnet to post, apply,
approve, deliver and get paid. The UI shows each wallet only its own actions,
and explains on-screen why a refund is locked whenever the guard blocks one.
The front end is three pages: the **Job board** (index), **Post a job**
(`post.html`) and **Payouts** (`payouts.html`), sharing one wallet session,
theme and script.

## The flow (current — JobBoardV5)

1. **Client posts a job** — title, requirements, pay per spot, number of
   spots, deadline — and the **full budget (pay × spots) is escrowed up
   front**. A spot on this board is guaranteed money, not a promise.
2. **Freelancers apply** — one application per wallet per job.
3. **Client approves the qualified** — approval allocates a spot. When the
   spots are gone, they're gone: first come, first approved.
4. **Approved freelancers deliver** with a proof link/hash attached.
5. **Client releases** each spot's pay individually from the pool.
6. **Guards:** an approved-but-undelivered spot can be reclaimed only after
   the deadline; a delivered spot only after the deadline **and** a 3-day
   review window. After deadline + review window the client closes the
   posting and the unspent budget returns to them.
7. **Disputes (V4):** if a client calls good work junk — or a freelancer
   claims pay for junk — either side can **open a dispute** on a delivered
   spot. The spot's pay **freezes** (no refund, no forced settlement) until
   a neutral **arbitrator** named in the contract reviews the delivery
   against the job requirements and rules: release to the freelancer, or
   refund to the client. The client can also settle voluntarily at any
   time by releasing.
8. **Two-way rating badges (V4/V5):** a freelancer who has actually held a
   settled spot with a client (paid or refunded) can give that client a
   **thumbs up or thumbs down** — one thumb per wallet, changeable — and
   the client can rate the freelancer back on the same terms. The public
   counts ride as badges: the client's on every job card (judge **before**
   applying), the freelancer's on their application rows (judge **before**
   approving).

## Payout layer (getting earnings out)

The **Payouts** page covers the final step of the payment flow,
with each route labelled for exactly what it is:

- **Withdraw as crypto — REAL.** A plain tUSD8 transfer from the earner's
  wallet to any external Aevum wallet address. Settles on-chain immediately.
- **Convert to another token — UNAVAILABLE, on purpose.** No swap route
  exists on the Aevum testnet: Q-Swap, QDay's DEX, currently runs on QDay
  Origin mainnet only and is announced to follow on Aevum (official QDay
  Wiki, FAQ §2.11). The UI shows the option as unavailable with that
  explanation rather than faking a swap.
- **Withdraw to local currency — QUOTE + REQUEST.** A transparent quote at
  a live FX rate (tUSD8 treated 1:1 with USD, stated on screen): gross, the
  **1% fee on its own line**, and the exact net amount, all shown before
  confirming. Confirming records a payout request (bank details + reference)
  labelled **SIMULATED** — actual bank settlement is a licensed-partner
  production step and is never presented as a real bank credit on testnet.

## Earlier versions (V1/V2 — the escrow this grew from)

Jobs came in two kinds:

- **Open jobs** — posted to the board with no freelancer assigned. Any
  qualified freelancer can **claim** one; the first claim takes it. Claiming
  is not a guarantee of work: the client funds only a claimer they accept,
  and until deposit either side can walk away. The funding decision is the
  qualification gate.
- **Direct hire** — created for one specific freelancer's wallet, as in V1.

1. **Client creates a job** — title, description, amount in tUSD8, deadline,
   and either a freelancer address (direct hire) or open posting.
2. **Freelancer accepts** the agreement — or **claims** an open job.
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

**Disputes (V4):** the guard alone can't judge quality, so a delivered spot
can be disputed by either side. Opening a dispute freezes that spot's pay —
the guard can no longer refund it and closing the posting leaves it locked —
until the contract's arbitrator rules release or refund. In production the
arbitrator role belongs to a platform review process (or multisig); on this
testnet build it is a dedicated wallet, and the role is transferable
on-chain.

## Contracts

| Contract | Address |
|---|---|
| JobBoardV5 (current — board + disputes + two-way ratings) | `0xe6948d9554e2bF73400922cbEfa663406B29ee44` |
| JobBoardV4 (board + disputes + client ratings) | `0xd0a22861122fcf221ab9c017457916ff9aa1a552` |
| JobBoard (V3 — funded postings + spots) | `0x37c8e35fb6c8f2f5d2a70dde6e7252fafcc99c6b` |
| FreelanceEscrowV2 (open job board) | `0x98ad3d72e7a92246606f91c078f5746758635b9f` |
| FreelanceEscrow (V1 — direct hire only) | `0x07310bcba28550d429f1d7d779f47e049f468b0e` |
| tUSD8 (official, QDay Aevum) | `0x456569838f1d43009A91ebA4263147Afd7233483` |

- Network: QDay Aevum testnet, chain ID `44005`
- RPC: `https://rpc-test.qday.info`
- Explorer: https://explorer-test.qday.info/address/0xe6948d9554e2bF73400922cbEfa663406B29ee44
- Deploy txs — V5: `0x83b085c2d66ebee9f18787013624047c84cdfd77832961e5b0a2a8b66a6dba00` · V4: `0x54cb32fab51aa46ca195288ed90d7e4cd41bf5e0669b8fd6a925c2eb006ca0c7` · V3: `0x562a4693fe3ab3e3d2dbcd919ba235e1de7d1b111265b4ac733bb9b642bf670a` · V2: `0xdb06b55b88e3553d2d7cf3341d66c2a0fd3b9a9989c53a7f94d66389b1b6ae04` · V1: `0x9ece21c6ef28a27db8cb2ce71523120419dd467383984a590ca8ec9e746d4b56`
- Source: **verified** on the explorer for all five versions

## Live dispute run on V4 (27 Nov 2026)

V4 launched with the same two funded postings (3 + 2 spots × 1 tUSD8) and
immediately ran the scenario the dispute path exists for — good work, a
client who won't release, a freelancer who appeals:

| Step | Tx |
|---|---|
| Apply | `0xe31affb747bb904f04822fd1957987749c43beecd649915b6e1c8019039d0e15` |
| Approve | `0x41d65fdb148ef38b83e283158910de816805ba0bbad2ac43a260e773d42af25f` |
| Deliver | `0xfe9800d76e4a3214a8b4b476f5bc064a3c5bafe51799b5d53be139b8ee12fe01` |
| **Open dispute** (freelancer) | `0xa8cbe7b6d2729f3bacc49d7f46cb72644829175d53cc450289387a02fd5be273` |
| **Arbitrator rules: pay freelancer** | `0x4517b2d07baf7558eff8eb1ccfbc4944f8b215172538d554b236222562e04aa4` |
| Freelancer rates the client 👍 | `0xe408fdb2a8f870ef8bbe637598e51c42123d5c7938413469c51003995ddba39a` |

Result: the arbitrator's ruling paid the freelancer in full (1 tUSD8), and
the client's public badge now reads **👍 1 · 👎 0** on the live board.

## Live board run (20 Nov 2026)

The board launched with two funded postings — *"Label 1,000 product images"*
(3 spots × 1 tUSD8) and *"Evaluate model responses (batch)"* (2 spots ×
1 tUSD8) — and immediately ran a full spot cycle: apply
(`0x9d074ec6f6e6ef31b319b5342f66a17b8b773292af6008982769741a29ece743`) →
approve (`0x35c1f5872f385d4e29d1870892bfed68c24305148acdc841edde43cb461c1808`) →
deliver (`0x6f1f464a3536f67faa026f54aa842b9ce19ee952cc0971ceed4510c123c19c10`) →
release (`0x44938e033fa45c1de5198e56e85d50e85f430d712a56f02de00562457264fe43`).
Four spots remain open across the two postings.

## Live open-job run on V2 (20 Nov 2026)

V2's first job was itself an open job: the client posted *"Label 500 product
images"* (AI training & evaluation, 5 tUSD8) with no freelancer assigned, a
freelancer **claimed** it (`0xdd6d34b172eed0b85f14f1af88f9a82750930fd344acc0b609f6a1fdab009ba2`),
the client funded it, the freelancer delivered, and release paid the full
5 tUSD8 (`0x840ab3f62e1339efeb9f005f923709fc0f153eb76dfe3c9223f5c1f296614aad`).
Two more open jobs sit on the board now, waiting for claimers.

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
forge test   # 73 tests: V1 spec checklist + V2 claim flow + V3 board flow + V4 disputes & client ratings + V5 two-way ratings
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
- [x] V2 open job board: anyone can post a job, qualified freelancers claim
      (19/19 tests, deployed + verified, live claim run completed)
- [x] V3 remote-work board: funded postings, limited spots, applications +
      qualification approvals, per-spot escrow (30/30 tests total, deployed +
      verified, live spot cycle completed, board seeded with open spots)
- [x] Payout layer: real crypto withdrawal; live-FX local-currency quote
      with the 1% fee itemised and requests recorded as labelled simulations;
      conversion honestly marked unavailable (no Aevum swap route exists)
- [x] V4 trust layer: dispute + arbitrator path (either side can dispute a
      delivered spot; pay freezes until the arbitrator rules) and public
      client rating badges (thumbs up/down from freelancers with a settled
      spot) — deployed + verified, live dispute run completed
- [x] V5: two-way badges — clients rate freelancers on the same settled-spot
      terms; the freelancer badge rides on application rows — 73/73 tests
      total, deployed + verified, live cycle rated both ways
- [ ] Payout options (after release): convert to other stablecoins, withdraw
      as crypto, or withdraw to local currency at a transparent quoted rate
      (bank settlement via a licensed partner in production; labelled as a
      simulation on testnet)

Testnet tokens only — nothing here has monetary value.
