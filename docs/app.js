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
  "function allowance(address owner, address spender) view returns (uint256)"
];
const A_STATES = ["Applied", "Approved", "Delivered", "Released", "Rejected", "Refunded"];

const readProvider = new ethers.JsonRpcProvider(RPC);
const boardRead = new ethers.Contract(BOARD, BOARD_ABI, readProvider);
const tokenRead = new ethers.Contract(TUSD8, ERC20_ABI, readProvider);

let signer = null, account = null, boardWrite = null, tokenWrite = null;
let postings = [], assignments = [], filter = "all", selectedId = null;

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
  renderList();
  if (selectedId !== null) renderDetail();
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
