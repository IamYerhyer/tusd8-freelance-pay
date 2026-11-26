// tUSD8 Freelance Pay — job board front end for the JobBoard contract (V3)
// on QDay Aevum testnet. Postings are funded up front with limited spots;
// freelancers apply, clients approve the qualified, delivery + release pay out.
const RPC = "https://rpc-test.qday.info";
const EXPLORER = "https://explorer-test.qday.info";
const CHAIN_ID = 44005;
const BOARD = "0x37c8e35fb6c8f2f5d2a70dde6e7252fafcc99c6b";
const TUSD8 = "0x456569838f1d43009A91ebA4263147Afd7233483";
const REVIEW_WINDOW = 3 * 24 * 3600;

const BOARD_ABI = [
  "function postingCount() view returns (uint256)",
  "function assignmentCount() view returns (uint256)",
  "function getPosting(uint256 id) view returns (tuple(address client, uint256 amountPerSpot, uint256 spotsTotal, uint256 spotsFilled, uint256 releasedCount, uint256 refundedCount, uint256 deadline, string title, string description, uint8 state, uint256 createdAt))",
  "function getAssignment(uint256 id) view returns (tuple(uint256 postingId, address freelancer, uint8 state, string proof, uint256 appliedAt, uint256 deliveredAt))",
  "function createPosting(uint256 amountPerSpot, uint256 spots, uint256 deadline, string title, string description) returns (uint256)",
  "function applyForSpot(uint256 postingId) returns (uint256)",
  "function approveApplication(uint256 assignmentId)",
  "function rejectApplication(uint256 assignmentId)",
  "function deliver(uint256 assignmentId, string proof)",
  "function release(uint256 assignmentId)",
  "function refundAssignment(uint256 assignmentId)",
  "function closePosting(uint256 postingId)"
];
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)"
];
const A_STATES = ["Applied", "Approved", "Delivered", "Released", "Rejected", "Refunded"];

const readProvider = new ethers.JsonRpcProvider(RPC);
const boardRead = new ethers.Contract(BOARD, BOARD_ABI, readProvider);
const tokenRead = new ethers.Contract(TUSD8, ERC20_ABI, readProvider);

let signer = null, account = null, boardWrite = null, tokenWrite = null;
let postings = [], assignments = [], filter = "all", selectedId = null, myFilter = "all";

const $ = (s) => document.querySelector(s);
const short = (a) => a.slice(0, 6) + "…" + a.slice(-4);
const fmtAmt = (raw) => (Number(raw) / 1e6).toLocaleString(undefined, { maximumFractionDigits: 6 });
const fmtDate = (sec) => new Date(Number(sec) * 1000).toLocaleString();
const same = (a, b) => a && b && a.toLowerCase() === b.toLowerCase();
const spotsLeft = (p) => Number(p.spotsTotal) - Number(p.spotsFilled);

function toast(html, ms = 6000) {
  const t = $("#toast");
  t.innerHTML = html;
  t.classList.remove("hidden");
  setTimeout(() => t.classList.add("hidden"), ms);
}
function txToast(hash) {
  toast(`✅ Confirmed: <a href="${EXPLORER}/tx/${hash}" target="_blank" rel="noopener">${short(hash)}</a> — view on explorer`, 9000);
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function parseCategory(desc) {
  const m = (desc || "").match(/^Category: (.+)$/m);
  return m ? m[1].trim() : null;
}
function categoryBadge(desc) {
  const c = parseCategory(desc);
  if (!c) return "";
  return ` <span class="badge ${c.startsWith("AI") ? "ai" : ""}">${escapeHtml(c)}</span>`;
}
function spotsBar(p) {
  const total = Number(p.spotsTotal), filled = Number(p.spotsFilled);
  const pct = total ? Math.round((filled / total) * 100) : 0;
  const left = total - filled;
  return `<div class="spots"><div class="spots-track"><div class="spots-fill" style="width:${pct}%"></div></div>
    <span>${left > 0 ? `<b>${left} of ${total} spots left</b>` : `<b class="full">All spots taken</b>`} · ${filled} approved · ${Number(p.releasedCount)} paid</span></div>`;
}

// ---------- data ----------
async function loadAll() {
  const pc = Number(await boardRead.postingCount());
  const ac = Number(await boardRead.assignmentCount());
  postings = [];
  for (let i = 0; i < pc; i++) {
    const p = await boardRead.getPosting(i);
    postings.push({ id: i, client: p.client, amountPerSpot: p.amountPerSpot, spotsTotal: p.spotsTotal,
      spotsFilled: p.spotsFilled, releasedCount: p.releasedCount, refundedCount: p.refundedCount,
      deadline: p.deadline, title: p.title, description: p.description, state: Number(p.state), createdAt: p.createdAt });
  }
  assignments = [];
  for (let i = 0; i < ac; i++) {
    const a = await boardRead.getAssignment(i);
    assignments.push({ id: i, postingId: Number(a.postingId), freelancer: a.freelancer,
      state: Number(a.state), proof: a.proof, appliedAt: a.appliedAt, deliveredAt: a.deliveredAt });
  }
  postings.reverse();
  renderStats();
  renderList();
  renderMyApps();
  if (selectedId !== null) renderDetail();
}

function renderStats() {
  const jobs = postings.length;
  const spots = postings.reduce((s, p) => s + Number(p.spotsTotal), 0);
  const paid = postings.reduce((s, p) => s + Number(p.releasedCount) * (Number(p.amountPerSpot) / 1e6), 0);
  const set = (id, v) => { const el = $(id); if (el) el.textContent = v; };
  set("#statJobs", jobs);
  set("#statSpots", spots);
  set("#statPaid", paid.toLocaleString(undefined, { maximumFractionDigits: 6 }));
}

function myAssignments() {
  return assignments.filter(a => same(a.freelancer, account));
}

function renderList() {
  const el = $("#jobList");
  let list = postings;
  if (filter === "posted") list = postings.filter(p => same(p.client, account));
  if (filter === "mine") {
    const ids = new Set(myAssignments().map(a => a.postingId));
    list = postings.filter(p => ids.has(p.id));
  }
  if (!list.length) {
    el.innerHTML = `<p class="muted">${filter === "all" ? "No jobs posted yet — post the first one below." : "Nothing in this view. Connect the matching wallet, or switch the filter."}</p>`;
    return;
  }
  el.innerHTML = list.map(p => `
    <div class="job-card" data-id="${p.id}">
      <h3>${escapeHtml(p.title)}${categoryBadge(p.description)} — <span class="amount">${fmtAmt(p.amountPerSpot)} tUSD8 / spot</span></h3>
      <div class="job-meta">
        <span>Client ${short(p.client)}</span><span>Deadline ${fmtDate(p.deadline)}</span>
        <span>${p.state === 1 ? "Closed" : "Open — budget funded in escrow"}</span>
      </div>
      ${spotsBar(p)}
    </div>`).join("");
  el.querySelectorAll(".job-card").forEach(c => c.addEventListener("click", () => openDetail(Number(c.dataset.id))));
}

// ---------- my applications ----------
const MY_FILTER_STATES = { all: null, pending: [0], approved: [1, 2], paid: [3], rejected: [4] };
const MY_HINTS = {
  0: "Waiting for the client's decision.",
  1: "You hold a funded spot — open the job to deliver your work.",
  2: "Delivered — waiting for the client to release your pay.",
  3: "Paid out to your wallet. ✅",
  4: "Not approved this time.",
  5: "This spot was refunded to the client under the guard rules."
};
function renderMyApps() {
  const el = $("#myAppsList");
  if (!el) return;
  const mine = myAssignments().slice().reverse(); // newest first
  const counts = {};
  for (const [key, states] of Object.entries(MY_FILTER_STATES)) {
    counts[key] = states === null ? mine.length : mine.filter(a => states.includes(a.state)).length;
  }
  document.querySelectorAll("#myAppsFilters [data-mfilter]").forEach(b => {
    const key = b.dataset.mfilter;
    const label = key[0].toUpperCase() + key.slice(1);
    b.textContent = mine.length ? `${label} (${counts[key]})` : label;
    b.classList.toggle("active", myFilter === key);
  });
  if (!account) {
    el.innerHTML = `<p class="muted">Connect your wallet to see the jobs you've applied for, grouped by the client's decision.</p>`;
    return;
  }
  if (!mine.length) {
    el.innerHTML = `<p class="muted">You haven't applied to any job yet — pick one from the board above and hit Apply for a spot.</p>`;
    return;
  }
  const states = MY_FILTER_STATES[myFilter];
  const list = states === null ? mine : mine.filter(a => states.includes(a.state));
  if (!list.length) {
    el.innerHTML = `<p class="muted">No ${myFilter} applications.</p>`;
    return;
  }
  el.innerHTML = list.map(a => {
    const p = postings.find(x => x.id === a.postingId);
    if (!p) return "";
    return `<div class="myapp-row">
      <div class="myapp-main">
        <div><b>${escapeHtml(p.title)}</b>${categoryBadge(p.description)} — <span class="amount">${fmtAmt(p.amountPerSpot)} tUSD8</span></div>
        <div class="job-meta"><span>Applied ${fmtDate(a.appliedAt)}</span><span>Job deadline ${fmtDate(p.deadline)}</span></div>
        <div class="myapp-hint">${MY_HINTS[a.state] || ""}</div>
      </div>
      <span class="status st-${a.state}">${A_STATES[a.state]}</span>
      <button data-open="${p.id}">Open job</button>
    </div>`;
  }).join("");
  el.querySelectorAll("[data-open]").forEach(b => b.addEventListener("click", () => openDetail(Number(b.dataset.open))));
}

// ---------- detail ----------
function refundGuardFor(a, p, nowSec) {
  if (a.state === 1) { // Approved
    return nowSec > Number(p.deadline)
      ? { enabled: true, reason: "Deadline passed, never delivered — refund unlocked." }
      : { enabled: false, reason: `Refund locked until the deadline (${fmtDate(p.deadline)}) if the freelancer never delivers.` };
  }
  if (a.state === 2) { // Delivered
    const reviewEnd = Number(a.deliveredAt) + REVIEW_WINDOW;
    const ok = nowSec > Number(p.deadline) && nowSec > reviewEnd;
    return ok
      ? { enabled: true, reason: "Deadline and 3-day review window have both passed — refund unlocked." }
      : { enabled: false, reason: `Refund locked: after delivery it needs the deadline and the 3-day review window (ends ${fmtDate(reviewEnd)}) to pass.` };
  }
  return { enabled: false, reason: "" };
}

function openDetail(id) {
  selectedId = id;
  $("#detailPanel").classList.remove("hidden");
  renderDetail();
  $("#detailPanel").scrollIntoView({ behavior: "smooth" });
}

function renderDetail() {
  const p = postings.find(x => x.id === selectedId);
  if (!p) return;
  const nowSec = Math.floor(Date.now() / 1000);
  const isClient = same(p.client, account);
  const list = assignments.filter(a => a.postingId === p.id);
  const mine = list.find(a => same(a.freelancer, account));
  $("#detailTitle").innerHTML = `${escapeHtml(p.title)}${categoryBadge(p.description)}`;

  let myBlock = "";
  if (!isClient) {
    if (!account) myBlock = `<p class="muted">Connect a wallet to apply for a spot.</p>`;
    else if (!mine) {
      myBlock = spotsLeft(p) > 0 && p.state === 0
        ? `<button class="primary" id="actApply">Apply for a spot</button> <span class="guard-note">Applying is free. The client approves qualified applicants — spots go first-come, first-approved.</span>`
        : `<p class="muted">${p.state === 1 ? "This posting is closed." : "All spots are taken."}</p>`;
    } else if (mine.state === 0) myBlock = `<p>Your application: <b>Applied</b> — waiting for the client to approve. Spots go to qualified applicants in order.</p>`;
    else if (mine.state === 1) myBlock = `<input id="proofInput" placeholder="Deliverable link or hash (proof)"><button class="primary" id="actDeliver">Deliver work</button> <span class="guard-note">You hold a funded spot. Deliver before the deadline to get paid.</span>`;
    else if (mine.state === 2) myBlock = `<p>Your delivery is in — waiting for the client to release your <b>${fmtAmt(p.amountPerSpot)} tUSD8</b>.</p>`;
    else if (mine.state === 3) myBlock = `<p class="tx-ok">✅ Paid — you earned ${fmtAmt(p.amountPerSpot)} tUSD8 for this spot.</p>`;
    else if (mine.state === 4) myBlock = `<p>Your application was not approved this time.</p>`;
    else if (mine.state === 5) myBlock = `<p>This spot was refunded to the client under the guard rules.</p>`;
  }

  const rows = list.map(a => {
    let controls = "";
    if (isClient) {
      if (a.state === 0) controls = `<button data-approve="${a.id}">Approve (qualify)</button> <button data-reject="${a.id}">Reject</button>`;
      if (a.state === 2) controls = `<button class="primary" data-release="${a.id}">Release ${fmtAmt(p.amountPerSpot)} tUSD8</button>`;
      if (a.state === 1 || a.state === 2) {
        const g = refundGuardFor(a, p, nowSec);
        controls += ` <button data-refund="${a.id}" ${g.enabled ? "" : "disabled"}>Refund spot</button> <span class="guard-note">${g.reason}</span>`;
      }
    }
    return `<div class="assign-row">
      <div><b>${short(a.freelancer)}</b> — ${A_STATES[a.state]}${a.proof ? ` · proof: ${escapeHtml(a.proof)}` : ""}${same(a.freelancer, account) ? " · (you)" : ""}</div>
      <div class="assign-controls">${controls}</div>
    </div>`;
  }).join("");

  const canClose = isClient && p.state === 0 && nowSec > Number(p.deadline) + REVIEW_WINDOW;
  const closeNote = isClient && p.state === 0
    ? (canClose
      ? `<button id="actClose">Close posting &amp; reclaim unspent budget</button>`
      : `<span class="guard-note">You can close this posting and reclaim the unspent budget after ${fmtDate(Number(p.deadline) + REVIEW_WINDOW)} (deadline + 3-day review window).</span>`)
    : "";

  $("#detailBody").innerHTML = `
    ${spotsBar(p)}
    <div class="detail-grid">
      <div><span>Pay per spot</span><b class="amount">${fmtAmt(p.amountPerSpot)} tUSD8</b></div>
      <div><span>Client</span><span>${p.client}</span></div>
      <div><span>Deadline</span><span>${fmtDate(p.deadline)}</span></div>
      <div><span>Status</span><span>${p.state === 1 ? "Closed" : "Open — full budget held in escrow"}</span></div>
      <div><span>Requirements</span><span class="pre">${escapeHtml(p.description)}</span></div>
    </div>
    <div class="actions">${myBlock}</div>
    <h3 class="sub">Applications &amp; spots (${list.length})</h3>
    ${rows || '<p class="muted">No applications yet — be the first.</p>'}
    <div class="actions">${closeNote}</div>`;

  const bind = (sel, fn) => { const b = $(sel); if (b) b.addEventListener("click", fn); };
  bind("#actApply", () => runTx(() => boardWrite.applyForSpot(p.id)));
  bind("#actDeliver", () => {
    const proof = $("#proofInput").value.trim();
    if (!proof) return toast("Add a deliverable link or hash first.");
    runTx(() => boardWrite.deliver(mine.id, proof));
  });
  bind("#actClose", () => runTx(() => boardWrite.closePosting(p.id)));
  document.querySelectorAll("[data-approve]").forEach(b => b.addEventListener("click", () => runTx(() => boardWrite.approveApplication(Number(b.dataset.approve)))));
  document.querySelectorAll("[data-reject]").forEach(b => b.addEventListener("click", () => runTx(() => boardWrite.rejectApplication(Number(b.dataset.reject)))));
  document.querySelectorAll("[data-release]").forEach(b => b.addEventListener("click", () => runTx(() => boardWrite.release(Number(b.dataset.release)))));
  document.querySelectorAll("[data-refund]").forEach(b => b.addEventListener("click", () => runTx(() => boardWrite.refundAssignment(Number(b.dataset.refund)))));
}

async function runTx(fn) {
  if (!signer) return toast("Connect your wallet first.");
  try {
    toast("Waiting for confirmation in your wallet…");
    const tx = await fn();
    toast(`Sent — waiting for the network… <a href="${EXPLORER}/tx/${tx.hash}" target="_blank" rel="noopener">${short(tx.hash)}</a>`);
    await tx.wait();
    txToast(tx.hash);
    await refreshBalances();
    await loadAll();
  } catch (e) {
    toast("Transaction failed: " + (e.shortMessage || e.message || e), 9000);
  }
}

// ---------- wallet ----------
async function ensureChain(provider) {
  const net = await provider.getNetwork();
  if (Number(net.chainId) === CHAIN_ID) return;
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x" + CHAIN_ID.toString(16) }] });
  } catch (e) {
    if (e.code === 4902) {
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [{ chainId: "0x" + CHAIN_ID.toString(16), chainName: "QDay Aevum Testnet",
          nativeCurrency: { name: "tQDAY", symbol: "tQDAY", decimals: 18 },
          rpcUrls: [RPC], blockExplorerUrls: [EXPLORER] }]
      });
    } else throw e;
  }
}

async function refreshBalances() {
  if (!account) { $("#balances").textContent = ""; return; }
  const p = new ethers.BrowserProvider(window.ethereum);
  const native = await p.getBalance(account);
  const t = await tokenRead.balanceOf(account);
  $("#balances").textContent = `Balance: ${ethers.formatEther(native).slice(0, 8)} tQDAY · ${fmtAmt(t)} tUSD8`;
}

async function connect() {
  if (!window.ethereum) {
    $("#banner").textContent = "No wallet extension found. Install MetaMask or Rabby, add the QDay Aevum testnet (chain 44005, RPC " + RPC + "), then connect. You can still browse the board below without a wallet.";
    $("#banner").classList.remove("hidden");
    return;
  }
  const provider = new ethers.BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []);
  await ensureChain(provider);
  signer = await provider.getSigner();
  account = await signer.getAddress();
  boardWrite = new ethers.Contract(BOARD, BOARD_ABI, signer);
  tokenWrite = new ethers.Contract(TUSD8, ERC20_ABI, signer);
  $("#connectBtn").textContent = "Connected";
  $("#accountLabel").textContent = account;
  await refreshBalances();
  renderList();
  renderMyApps();
  if (selectedId !== null) renderDetail();
}

// ---------- wiring ----------
$("#connectBtn").addEventListener("click", connect);
$("#refreshBtn").addEventListener("click", loadAll);
$("#closeDetail").addEventListener("click", () => { selectedId = null; $("#detailPanel").classList.add("hidden"); });
document.querySelectorAll(".filter[data-filter]").forEach(b => b.addEventListener("click", () => {
  document.querySelectorAll(".filter[data-filter]").forEach(x => x.classList.remove("active"));
  b.classList.add("active");
  filter = b.dataset.filter;
  renderList();
}));
document.querySelectorAll("#myAppsFilters [data-mfilter]").forEach(b => b.addEventListener("click", () => {
  myFilter = b.dataset.mfilter;
  renderMyApps();
}));
$("#categorySelect").addEventListener("change", (e) => {
  $("#aiFields").classList.toggle("hidden", e.target.value !== "AI training & evaluation");
});
function updateTotal() {
  const f = new FormData($("#createForm"));
  const per = parseFloat(f.get("amount")) || 0, spots = parseInt(f.get("spots")) || 0;
  $("#totalNote").textContent = spots && per
    ? `Total budget to fund up front: ${(per * spots).toLocaleString(undefined, { maximumFractionDigits: 6 })} tUSD8 (${spots} spots × ${per} tUSD8). Unspent budget returns after the deadline.`
    : "Posting funds the full budget (pay × spots) into escrow up front — that's what makes every spot on this board real. Unspent budget returns after the deadline.";
}
$("#createForm").addEventListener("input", updateTotal);
$("#createForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  if (!signer) return toast("Connect your wallet first — posting a job is a transaction.");
  const f = new FormData(e.target);
  const deadline = Math.floor(new Date(f.get("deadline") + "T23:59:59").getTime() / 1000);
  const perSpot = ethers.parseUnits(String(f.get("amount")), 6);
  const spots = BigInt(f.get("spots"));
  const total = perSpot * spots;
  const lines = [`Category: ${f.get("category")}`];
  if (f.get("category") === "AI training & evaluation") {
    lines.push(`AI task type: ${f.get("aiTaskType")}`);
    const instr = String(f.get("aiInstructions") || "").trim();
    if (instr) lines.push(`Instructions: ${instr}`);
  }
  const free = String(f.get("description") || "").trim();
  if (free) lines.push("", free);
  const description = lines.join("\n");
  const allowance = await tokenWrite.allowance(account, BOARD);
  if (allowance < total) {
    toast("Step 1 of 2: approve the board to hold the job budget…");
    try {
      const tx = await tokenWrite.approve(BOARD, total);
      await tx.wait();
      txToast(tx.hash);
    } catch (err) { return toast("Approval failed: " + (err.shortMessage || err.message), 9000); }
  }
  toast("Step 2 of 2: posting the job and funding its spots…");
  await runTx(() => boardWrite.createPosting(perSpot, spots, deadline, f.get("title"), description));
  e.target.reset();
  updateTotal();
});
if (window.ethereum) window.ethereum.on("accountsChanged", () => location.reload());
loadAll().catch(() => { $("#jobList").innerHTML = '<p class="muted">Could not reach the Aevum RPC — try Refresh in a moment.</p>'; });

// ---------- payouts ----------
// B) Crypto withdrawal: a plain ERC-20 transfer from the connected wallet —
//    fully real on testnet.
$("#wdBtn").addEventListener("click", async () => {
  if (!signer) return toast("Connect your wallet first.");
  const to = $("#wdAddress").value.trim();
  const amt = $("#wdAmount").value;
  if (!/^0x[0-9a-fA-F]{40}$/.test(to)) return toast("Enter a valid destination wallet address.");
  if (!amt || Number(amt) <= 0) return toast("Enter an amount to withdraw.");
  await runTx(() => tokenWrite.transfer(to, ethers.parseUnits(String(amt), 6)));
});

// C) Local-currency payout: live FX quote (tUSD8 treated 1:1 with USD, stated
//    on screen), 1% fee on its own line, exact net before confirming. The
//    request is recorded locally; bank settlement is a licensed-partner
//    production step, so the record is labelled SIMULATED.
let fxRates = null, fxRateTime = null;
async function loadFxRates() {
  try {
    const r = await fetch("https://open.er-api.com/v6/latest/USD");
    const j = await r.json();
    if (j && j.rates) { fxRates = j.rates; fxRateTime = j.time_last_update_utc || ""; }
  } catch (e) { fxRates = null; }
  renderFxQuote();
}
const fxFmt = (n, cur) => n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " " + cur;
function currentQuote() {
  const amt = Number($("#fxAmount").value);
  const cur = $("#fxCurrency").value;
  if (!amt || amt <= 0 || !fxRates || !fxRates[cur]) return null;
  const rate = fxRates[cur];
  const gross = amt * rate;
  const fee = gross * 0.01;
  return { amt, cur, rate, gross, fee, net: gross - fee };
}
function renderFxQuote() {
  const box = $("#fxQuote");
  const q = currentQuote();
  if (!$("#fxAmount").value) { box.innerHTML = "Enter an amount to see the live quote."; return; }
  if (!fxRates) { box.innerHTML = "Live rate unavailable right now — check your connection and try again. No quote, no request: we never guess a rate."; return; }
  if (!q) { box.innerHTML = "Enter a valid amount."; return; }
  box.innerHTML = `
    <div><span>Rate (live, 1 tUSD8 = 1 USD)</span><b>1 USD = ${q.rate.toLocaleString(undefined, { maximumFractionDigits: 4 })} ${q.cur}</b></div>
    <div><span>Amount</span><span>${q.amt} tUSD8 → ${fxFmt(q.gross, q.cur)}</span></div>
    <div><span>Fee (1%)</span><span>− ${fxFmt(q.fee, q.cur)}</span></div>
    <div class="net"><span>You would receive</span><span>${fxFmt(q.net, q.cur)}</span></div>
    <div><span class="small muted">Rate source: open.er-api.com${fxRateTime ? " · updated " + escapeHtml(fxRateTime) : ""}. Exact net shown before you confirm — no hidden charges.</span></div>`;
}
["#fxAmount", "#fxCurrency"].forEach(s => { $(s).addEventListener("input", renderFxQuote); $(s).addEventListener("change", renderFxQuote); });

function fxRequests() {
  try { return JSON.parse(localStorage.getItem("tfp-payout-requests") || "[]"); } catch (e) { return []; }
}
function renderFxRequests() {
  const list = fxRequests();
  const el = $("#fxRequests");
  if (!list.length) { el.innerHTML = ""; return; }
  el.innerHTML = `<h3 class="sub">Your payout requests</h3>` + list.map(r => `
    <div class="fx-req">
      <div><b>${escapeHtml(r.ref)}</b> · ${r.amount} tUSD8 → <b>${escapeHtml(r.net)}</b> · ${escapeHtml(r.bank)} ····${escapeHtml(r.accountLast4)} (${escapeHtml(r.name)})</div>
      <div><span class="sim">SIMULATED</span> <span class="muted">· recorded ${escapeHtml(r.when)} · bank settlement is a production step</span></div>
    </div>`).join("");
}
$("#fxBtn").addEventListener("click", () => {
  const q = currentQuote();
  if (!q) return toast("Enter an amount and wait for the live quote first.");
  const bank = $("#fxBank").value.trim();
  const acct = $("#fxAccount").value.trim();
  const name = $("#fxName").value.trim();
  if (!bank || !acct || !name) return toast("Fill in the bank name, account number and account name.");
  if (!account) return toast("Connect your wallet first so the request is tied to the wallet that earned the tUSD8.");
  const ref = "TFP-" + Date.now().toString(36).toUpperCase();
  const req = {
    ref, amount: q.amt, currency: q.cur, net: fxFmt(q.net, q.cur),
    bank, accountLast4: acct.slice(-4), name,
    from: account, when: new Date().toLocaleString()
  };
  const list = fxRequests();
  list.unshift(req);
  try { localStorage.setItem("tfp-payout-requests", JSON.stringify(list.slice(0, 20))); } catch (e) {}
  renderFxRequests();
  toast(`Payout request <b>${ref}</b> recorded — ${fxFmt(q.net, q.cur)} to ${escapeHtml(bank)}. Labelled SIMULATED: on testnet no bank credit occurs; settlement is the licensed-partner production step.`, 10000);
});
loadFxRates();
renderFxRequests();
