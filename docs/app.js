// tUSD8 Freelance Pay — front end for the FreelanceEscrow contract on QDay Aevum testnet.
const RPC = "https://rpc-test.qday.info";
const EXPLORER = "https://explorer-test.qday.info";
const CHAIN_ID = 44005;
const ESCROW = "0x07310bcba28550d429f1d7d779f47e049f468b0e";
const TUSD8 = "0x456569838f1d43009A91ebA4263147Afd7233483";
const REVIEW_WINDOW = 3 * 24 * 3600; // seconds, mirrors the contract

const ESCROW_ABI = [
  "function agreementCount() view returns (uint256)",
  "function getAgreement(uint256 id) view returns (tuple(address client, address freelancer, uint256 amount, string title, string description, uint256 deadline, uint8 state, string deliverableProof, uint256 createdAt, uint256 fundedAt, uint256 deliveredAt))",
  "function createAgreement(address freelancer, uint256 amount, uint256 deadline, string title, string description) returns (uint256)",
  "function acceptAgreement(uint256 id)",
  "function deposit(uint256 id)",
  "function markDelivered(uint256 id, string proof)",
  "function release(uint256 id)",
  "function refund(uint256 id)"
];
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)"
];
const STATES = ["Created", "Accepted", "Funded", "Delivered", "Released", "Refunded"];

const readProvider = new ethers.JsonRpcProvider(RPC);
const escrowRead = new ethers.Contract(ESCROW, ESCROW_ABI, readProvider);
const tokenRead = new ethers.Contract(TUSD8, ERC20_ABI, readProvider);

let signer = null, account = null, escrowWrite = null, tokenWrite = null;
let jobs = [], filter = "all", selectedId = null;

const $ = (s) => document.querySelector(s);
const short = (a) => a.slice(0, 6) + "…" + a.slice(-4);
const fmtAmt = (raw) => (Number(raw) / 1e6).toLocaleString(undefined, { maximumFractionDigits: 6 });
const fmtDate = (sec) => new Date(Number(sec) * 1000).toLocaleString();
const same = (a, b) => a && b && a.toLowerCase() === b.toLowerCase();

function toast(html, ms = 6000) {
  const t = $("#toast");
  t.innerHTML = html;
  t.classList.remove("hidden");
  setTimeout(() => t.classList.add("hidden"), ms);
}
function txToast(hash) {
  toast(`✅ Confirmed: <a href="${EXPLORER}/tx/${hash}" target="_blank" rel="noopener">${short(hash)}</a> — view on explorer`, 9000);
}

// ---------- job list ----------
function stepper(state) {
  if (state === 5) return `<div class="stepper"><div class="step refunded"><span class="dot">✕</span>Refunded</div></div>`;
  const steps = ["Created", "Accepted", "Funded", "Delivered", "Released"];
  return `<div class="stepper">` + steps.map((s, i) => {
    const cls = i < state ? "done" : i === state ? "current" : "";
    const mark = i < state ? "✓" : i + 1;
    return `${i ? '<span class="bar"></span>' : ""}<div class="step ${cls}"><span class="dot">${mark}</span>${s}</div>`;
  }).join("") + `</div>`;
}

async function loadJobs() {
  const count = Number(await escrowRead.agreementCount());
  const out = [];
  for (let i = 0; i < count; i++) {
    const a = await escrowRead.getAgreement(i);
    out.push({ id: i, client: a.client, freelancer: a.freelancer, amount: a.amount, title: a.title,
      description: a.description, deadline: a.deadline, state: Number(a.state),
      proof: a.deliverableProof, createdAt: a.createdAt, fundedAt: a.fundedAt, deliveredAt: a.deliveredAt });
  }
  jobs = out.reverse();
  renderList();
  if (selectedId !== null) renderDetail();
}

function renderList() {
  const el = $("#jobList");
  const mine = jobs.filter(j =>
    filter === "all" ? true :
    filter === "client" ? same(j.client, account) :
    same(j.freelancer, account));
  if (!mine.length) {
    el.innerHTML = `<p class="muted">${filter === "all" ? "No jobs yet — create the first one below." : "No jobs in this view. Connect the matching wallet, or switch the filter."}</p>`;
    return;
  }
  el.innerHTML = mine.map(j => `
    <div class="job-card" data-id="${j.id}">
      <h3>#${j.id} · ${escapeHtml(j.title)} — <span class="amount">${fmtAmt(j.amount)} tUSD8</span></h3>
      <div class="job-meta">
        <span>Client ${short(j.client)}</span><span>Freelancer ${short(j.freelancer)}</span>
        <span>Deadline ${fmtDate(j.deadline)}</span><span>State: ${STATES[j.state]}</span>
      </div>
      ${stepper(j.state)}
    </div>`).join("");
  el.querySelectorAll(".job-card").forEach(c => c.addEventListener("click", () => openDetail(Number(c.dataset.id))));
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// ---------- job detail ----------
function refundGuard(j, nowSec) {
  // Mirrors the contract's refund rules; returns {enabled, reason}
  if (j.state === 0 || j.state === 1) return { enabled: true, reason: "Nothing deposited yet — cancelling is free." };
  if (j.state === 2) {
    return nowSec > Number(j.deadline)
      ? { enabled: true, reason: "Deadline passed and the freelancer never delivered — refund unlocked." }
      : { enabled: false, reason: `Locked: the deposit can only be refunded after the deadline (${fmtDate(j.deadline)}) if the freelancer never delivers. This stops a client pulling funding mid-job.` };
  }
  if (j.state === 3) {
    const reviewEnd = Number(j.deliveredAt) + REVIEW_WINDOW;
    const ok = nowSec > Number(j.deadline) && nowSec > reviewEnd;
    if (ok) return { enabled: true, reason: "Deadline and the 3-day review window have both passed — refund unlocked." };
    const pending = [];
    if (nowSec <= Number(j.deadline)) pending.push(`the deadline (${fmtDate(j.deadline)})`);
    if (nowSec <= reviewEnd) pending.push(`the 3-day review window (ends ${fmtDate(reviewEnd)})`);
    return { enabled: false, reason: `Locked: after delivery a refund needs both ${pending.join(" and ")} to pass. The freelancer can't lose pay for delivered work inside the window.` };
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
  const j = jobs.find(x => x.id === selectedId);
  if (!j) return;
  const nowSec = Math.floor(Date.now() / 1000);
  const isClient = same(j.client, account), isFreelancer = same(j.freelancer, account);
  const role = isClient ? "You are the client on this job." : isFreelancer ? "You are the freelancer on this job."
    : account ? "You are not a party to this job — actions are disabled." : "Connect a wallet to act on this job.";
  $("#detailTitle").textContent = `Job #${j.id} — ${j.title}`;
  let actions = "";
  if (j.state === 0 && isFreelancer) actions += `<button class="primary" id="actAccept">Accept job</button>`;
  if (j.state === 1 && isClient) actions += `<button class="primary" id="actDeposit">Deposit ${fmtAmt(j.amount)} tUSD8</button>`;
  if (j.state === 2 && isFreelancer) actions += `<input id="proofInput" placeholder="Deliverable link or hash (proof)"><button class="primary" id="actDeliver">Mark delivered</button>`;
  if (j.state === 3 && isClient) actions += `<button class="primary" id="actRelease">Release ${fmtAmt(j.amount)} tUSD8 to freelancer</button>`;
  if (isClient && [0, 1, 2, 3].includes(j.state)) {
    const g = refundGuard(j, nowSec);
    actions += `<button id="actRefund" ${g.enabled ? "" : "disabled"}>${j.state <= 1 ? "Cancel job" : "Refund deposit"}</button><span class="guard-note">${g.reason}</span>`;
  }
  $("#detailBody").innerHTML = `
    ${stepper(j.state)}
    <div class="detail-grid">
      <div><span>Amount</span><b class="amount">${fmtAmt(j.amount)} tUSD8</b></div>
      <div><span>State</span><b>${STATES[j.state]}</b></div>
      <div><span>Client</span><span>${j.client}</span></div>
      <div><span>Freelancer</span><span>${j.freelancer}</span></div>
      <div><span>Description</span><span>${escapeHtml(j.description || "—")}</span></div>
      <div><span>Deadline</span><span>${fmtDate(j.deadline)}</span></div>
      ${j.proof ? `<div><span>Deliverable proof</span><span>${escapeHtml(j.proof)}</span></div>` : ""}
      <div><span>Your role</span><span>${role}</span></div>
    </div>
    <div class="actions">${actions || '<span class="muted">No actions available in this state.</span>'}</div>`;
  const bind = (id, fn) => { const b = $(id); if (b) b.addEventListener("click", fn); };
  bind("#actAccept", () => runTx(() => escrowWrite.acceptAgreement(j.id)));
  bind("#actDeposit", depositFlow);
  bind("#actDeliver", () => {
    const proof = $("#proofInput").value.trim();
    if (!proof) return toast("Add a deliverable link or hash first.");
    runTx(() => escrowWrite.markDelivered(j.id, proof));
  });
  bind("#actRelease", () => runTx(() => escrowWrite.release(j.id)));
  bind("#actRefund", () => runTx(() => escrowWrite.refund(j.id)));
}

async function depositFlow() {
  const j = jobs.find(x => x.id === selectedId);
  const allowance = await tokenWrite.allowance(account, ESCROW);
  if (allowance < j.amount) {
    toast("Step 1 of 2: approve the escrow to hold your tUSD8…");
    const tx = await tokenWrite.approve(ESCROW, j.amount);
    await tx.wait();
    txToast(tx.hash);
  }
  toast("Step 2 of 2: depositing into escrow…");
  runTx(() => escrowWrite.deposit(j.id));
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
    await loadJobs();
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
  const p = signer ? new ethers.BrowserProvider(window.ethereum) : readProvider;
  const native = await p.getBalance(account);
  const t = await tokenRead.balanceOf(account);
  $("#balances").textContent = `Balance: ${ethers.formatEther(native).slice(0, 8)} tQDAY · ${fmtAmt(t)} tUSD8`;
}

async function connect() {
  if (!window.ethereum) {
    $("#banner").textContent = "No wallet extension found. Install MetaMask or Rabby, add the QDay Aevum testnet (chain 44005, RPC " + RPC + "), then connect. You can still browse all jobs below without a wallet.";
    $("#banner").classList.remove("hidden");
    return;
  }
  const provider = new ethers.BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []);
  await ensureChain(provider);
  signer = await provider.getSigner();
  account = await signer.getAddress();
  escrowWrite = new ethers.Contract(ESCROW, ESCROW_ABI, signer);
  tokenWrite = new ethers.Contract(TUSD8, ERC20_ABI, signer);
  $("#connectBtn").textContent = "Connected";
  $("#accountLabel").textContent = account;
  await refreshBalances();
  renderList();
  if (selectedId !== null) renderDetail();
}

// ---------- wiring ----------
$("#connectBtn").addEventListener("click", connect);
$("#refreshBtn").addEventListener("click", loadJobs);
$("#closeDetail").addEventListener("click", () => { selectedId = null; $("#detailPanel").classList.add("hidden"); });
document.querySelectorAll(".filter[data-filter]").forEach(b => b.addEventListener("click", () => {
  document.querySelectorAll(".filter[data-filter]").forEach(x => x.classList.remove("active"));
  b.classList.add("active");
  filter = b.dataset.filter;
  renderList();
}));
$("#createForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  if (!signer) return toast("Connect your wallet first — creating a job is a transaction.");
  const f = new FormData(e.target);
  const deadline = Math.floor(new Date(f.get("deadline") + "T23:59:59").getTime() / 1000);
  const amount = ethers.parseUnits(String(f.get("amount")), 6);
  await runTx(() => escrowWrite.createAgreement(f.get("freelancer"), amount, deadline, f.get("title"), f.get("description") || ""));
  e.target.reset();
});
if (window.ethereum) window.ethereum.on("accountsChanged", () => location.reload());
loadJobs().catch(() => { $("#jobList").innerHTML = '<p class="muted">Could not reach the Aevum RPC — try Refresh in a moment.</p>'; });
