#!/usr/bin/env node
// Recycling Ledger helper for the ATOMYX Reclaim Vault. Reads the chain; never signs or sends anything.
//
//   node ledger/batch.mjs prepare <draft.json>   validate a real collected batch, write its public evidence file
//                                                 ledger/batches/<id>.json and print the recordBatch inputs
//   node ledger/batch.mjs status <id>             read the batch on-chain and print the payReward inputs
//
// The evidence hash recorded on-chain is keccak256 of the exact bytes of ledger/batches/<id>.json, so anyone can
// check a ledger entry by hashing the published file. ETH_RPC_URL overrides the default public RPC.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256 } from "./keccak.mjs";

const VAULT = "0xE031C733817b09228B8D443c5770F5864899377D";
const LAUNCH_WALLET = "0xD14148ebFD28D664f1B89A4d6CCcfca002446B7b";
const RPC = process.env.ETH_RPC_URL ?? "https://ethereum-rpc.publicnode.com";
const BLOCKSCOUT = `https://eth.blockscout.com/address/${VAULT}?tab=write_contract`;
const MATERIALS = ["PET", "HDPE", "PP", "OTHER_PLASTIC", "METAL", "PAPER", "GLASS", "E_WASTE"];
const CHECKPOINTS = ["point", "sorting", "recycler"];
const MAX_SPREAD = 0.05;
const REVIEW_SECONDS = 24 * 3600;
const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "batches");

class Stop extends Error {}
const fail = (m) => { throw new Stop(m); };
const isAddr = (a) => typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a);
const isUrl = (u) => typeof u === "string" && /^https:\/\/\S+$/.test(u);
const eth = (wei) => (Number(wei) / 1e18).toFixed(6);

// ------------------------------------------------------------------ minimal JSON-RPC reads
const sel = (sig) => keccak256(sig).slice(0, 10);
const word = (hex, i) => BigInt("0x" + hex.slice(2 + i * 64, 2 + (i + 1) * 64));
async function call(sig, arg = "") {
  const res = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: VAULT, data: sel(sig) + arg }, "latest"] }) });
  const j = await res.json();
  if (j.error) fail(`RPC ${sig}: ${j.error.message}`);
  return j.result;
}
const addrOf = (hex) => "0x" + hex.slice(-40);
async function chainTime() {
  const res = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["latest", false] }) });
  return Number(BigInt((await res.json()).result.timestamp));
}
async function vaultState() {
  const [rate, pool, guardian, attester, treasury] = await Promise.all([
    call("maxWeiPerKg()"), call("rewardsPool()"), call("guardian()"), call("attester()"), call("treasury()")]);
  return { maxWeiPerKg: word(rate, 0), rewardsPool: word(pool, 0), guardian: addrOf(guardian), attester: addrOf(attester), treasury: addrOf(treasury) };
}
async function batchOnChain(batchId) {
  const r = await call("batches(bytes32)", batchId.slice(2));
  return { grams: word(r, 0), paidWei: word(r, 1), recordedAt: word(r, 2), material: Number(word(r, 3)), voided: word(r, 4) === 1n,
    evidenceHash: "0x" + word(r, 5).toString(16).padStart(64, "0") };
}

// ------------------------------------------------------------------ canonical evidence file
const sortKeys = (v) => Array.isArray(v) ? v.map(sortKeys)
  : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])])) : v;
const canonical = (obj) => JSON.stringify(sortKeys(obj), null, 2) + "\n";

function validate(b, team) {
  if (typeof b.id !== "string" || !/^ATMX-\d{4}-\d{4,}$/.test(b.id)) fail('id must look like "ATMX-2026-0001"');
  if (!MATERIALS.includes(b.material)) fail("material must be one of " + MATERIALS.join(", "));
  if (!b.collector || !isAddr(b.collector.wallet)) fail("collector.wallet must be the collector's own address");
  if (team.has(b.collector.wallet.toLowerCase())) fail("collector.wallet is a team wallet: rewards go to the people who collected the waste");
  if (!b.point || !b.point.name || !b.point.city) fail("point.name and point.city are required");
  if (!Array.isArray(b.weighings) || b.weighings.length !== 3) fail("weighings must list exactly three checkpoints");
  const seen = b.weighings.map((w) => w.checkpoint).sort().join(",");
  if (seen !== [...CHECKPOINTS].sort().join(",")) fail("weighings must be one each of: " + CHECKPOINTS.join(", "));
  for (const w of b.weighings) {
    if (!Number.isSafeInteger(w.grams) || w.grams <= 0) fail(`${w.checkpoint}: grams must be a positive whole number`);
    if (!w.at || Number.isNaN(Date.parse(w.at))) fail(`${w.checkpoint}: at must be a date-time, e.g. 2026-10-26T09:30:00Z`);
    if (Date.parse(w.at) > Date.now() + 3600e3) fail(`${w.checkpoint}: weighing time is in the future`);
    if (!Array.isArray(w.photos) || w.photos.length === 0 || !w.photos.every(isUrl)) fail(`${w.checkpoint}: at least one https photo of the scale reading`);
  }
  const r = b.recyclerReceipt;
  if (!r || !r.recycler || !r.reference || !isUrl(r.url)) fail("recyclerReceipt needs recycler, reference and an https url of the receipt");
  const grams = b.weighings.map((w) => w.grams);
  const spread = (Math.max(...grams) - Math.min(...grams)) / Math.max(...grams);
  if (spread > MAX_SPREAD) fail(`checkpoint weights differ by ${(spread * 100).toFixed(1)}% (> 5%): hold the batch for review, do not record it`);
  return { recordedGrams: Math.min(...grams), spread };
}

// ------------------------------------------------------------------ commands
async function prepare(file) {
  const draft = JSON.parse(readFileSync(file, "utf8"));
  const v = await vaultState();
  const team = new Set([LAUNCH_WALLET, v.guardian, v.attester, v.treasury].map((a) => a.toLowerCase()));
  const { recordedGrams, spread } = validate(draft, team);
  const batchId = keccak256(draft.id);
  const existing = await batchOnChain(batchId);
  if (existing.recordedAt !== 0n) fail(`${draft.id} is already recorded on-chain`);
  const evidence = { ...draft, schema: "atomyx.recycling-batch.v1", vault: VAULT, batchId, recordedGrams, checkpointSpreadPct: +(spread * 100).toFixed(2) };
  const bytes = canonical(evidence);
  mkdirSync(dir, { recursive: true });
  const out = path.join(dir, `${draft.id}.json`);
  if (existsSync(out) && readFileSync(out, "utf8") !== bytes) fail(`${out} exists with different content`);
  writeFileSync(out, bytes);
  const evidenceHash = keccak256(bytes);
  const cap = BigInt(recordedGrams) * v.maxWeiPerKg / 1000n;
  console.log(`✓ ${draft.id}: ${MATERIALS[MATERIALS.indexOf(draft.material)]}, ${recordedGrams} g (lowest of three; spread ${(spread * 100).toFixed(2)}%)`);
  console.log(`  evidence file: ledger/batches/${draft.id}.json  (publish it to GitHub BEFORE recording)`);
  console.log(`  reward cap: ${eth(cap)} ETH · rewards pool now: ${eth(v.rewardsPool)} ETH`);
  console.log(`\nrecordBatch on ${BLOCKSCOUT}  (sign with the attester ${v.attester})`);
  console.log(`  batchId       ${batchId}`);
  console.log(`  material      ${MATERIALS.indexOf(draft.material)}`);
  console.log(`  grams         ${recordedGrams}`);
  console.log(`  evidenceHash  ${evidenceHash}`);
}

async function status(id) {
  const file = path.join(dir, `${id}.json`);
  if (!existsSync(file)) fail(`no evidence file ledger/batches/${id}.json`);
  const bytes = readFileSync(file, "utf8");
  const ev = JSON.parse(bytes);
  const v = await vaultState();
  const b = await batchOnChain(ev.batchId);
  if (b.recordedAt === 0n) fail(`${id} is not recorded on-chain yet`);
  if (b.evidenceHash !== keccak256(bytes)) fail("on-chain evidenceHash does not match the evidence file: do not pay");
  const cap = b.grams * v.maxWeiPerKg / 1000n;
  const left = cap - b.paidWei;
  const payableAt = Number(b.recordedAt) + REVIEW_SECONDS;
  console.log(`${id}: ${MATERIALS[b.material]}, ${b.grams} g, recorded ${new Date(Number(b.recordedAt) * 1000).toISOString()}`);
  console.log(`  evidence hash matches the published file ✓`);
  console.log(`  paid ${eth(b.paidWei)} of cap ${eth(cap)} ETH · pool ${eth(v.rewardsPool)} ETH${b.voided ? " · VOIDED" : ""}`);
  if (b.voided) return console.log("  voided batches can never be paid");
  if ((await chainTime()) < payableAt) return console.log(`  in public review until ${new Date(payableAt * 1000).toISOString()}`);
  const amount = [left, v.rewardsPool].reduce((a, c) => (c < a ? c : a));
  if (left <= 0n) return console.log("  this batch has been paid in full");
  if (amount <= 0n) return console.log(`  the rewards pool is empty; ${eth(left)} ETH of this batch's cap waits for new fees`);
  console.log(`\npayReward on ${BLOCKSCOUT}  (sign with the guardian ${v.guardian})`);
  console.log(`  batchId  ${ev.batchId}`);
  console.log(`  to       ${ev.collector.wallet}  (collector)`);
  console.log(`  amount   ${amount}  (wei = ${eth(amount)} ETH; may be lower)`);
}

const [cmd, arg] = process.argv.slice(2);
try {
  if (cmd === "prepare" && arg) await prepare(arg);
  else if (cmd === "status" && arg) await status(arg);
  else fail("usage: node ledger/batch.mjs prepare <draft.json> | status <ATMX-YYYY-NNNN>");
} catch (e) {
  if (!(e instanceof Stop)) throw e;
  console.error("✗ " + e.message);
  process.exitCode = 1;
}
