#!/usr/bin/env node
// Read-only: compares the code hash of every deployed ONRANK contract (toncenter v3 account states) with the hash of
// the corresponding local build artifact (contracts/build/<Name>.json). Prints a table; exits 1 on any mismatch.
//
//   node scripts/check-code-hashes.mjs                 # mainnet, addresses from https://onrank.lol/api/config + /api/coins
//   node scripts/check-code-hashes.mjs --json          # machine-readable
//
// Used by docs/integration/VERIFY.md: an integrator can run it before trusting the published sources.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const API = process.env.ONRANK_API ?? "https://onrank.lol";
const TONCENTER = process.env.TONCENTER_URL ?? "https://toncenter.com";
const json = process.argv.includes("--json");

const config = await (await fetch(`${API}/api/config`)).json();
const coins = await (await fetch(`${API}/api/coins`)).json();
const rank = coins.find((c) => c.seq === config.desk.launchSeq) ?? coins[0];

// deployed account → build artifact
const targets = [
  ["FactoryV2", config.accounts.factory],
  ["Pot", config.accounts.pot],
  ["DeskMinter", config.accounts.minter],
  ["DeskCollection", config.accounts.collection],
  ["BuybackVault", config.accounts.buyback],
  ["RewardMasterV2", rank?.master],
  ["CurveV2", rank?.curve],
  ["PoolV2", rank?.pool],
].filter(([, a]) => a);
if (process.env.POT_RELAY) targets.push(["PotRelay", process.env.POT_RELAY]);

const toFriendly = (raw) => raw; // toncenter accepts raw "0:..." and friendly forms
const rows = [];
for (const [name, address] of targets) {
  const artifact = path.join(here, "..", "build", `${name}.json`);
  const local = fs.existsSync(artifact) ? JSON.parse(fs.readFileSync(artifact, "utf8")).hash : null;
  // public toncenter rate-limits anonymous callers: retry with a pause instead of reporting a false mismatch
  let state = null;
  for (let attempt = 0; attempt < 4 && !state; attempt++) {
    if (attempt) await new Promise((res) => setTimeout(res, 1500 * attempt));
    const res = await fetch(`${TONCENTER}/api/v3/accountStates?address=${encodeURIComponent(toFriendly(address))}&include_boc=false`, { headers: process.env.TONCENTER_API_KEY ? { "X-API-Key": process.env.TONCENTER_API_KEY } : {} });
    if (res.ok) state = (await res.json()).accounts?.[0] ?? null;
  }
  const onChain = state?.code_hash ?? null; // base64
  const localB64 = local ? Buffer.from(local, "hex").toString("base64") : null;
  rows.push({ name, address, onChain, local: localB64, match: onChain !== null && localB64 !== null && onChain === localB64 });
  await new Promise((res) => setTimeout(res, 700));
}
if (json) console.log(JSON.stringify(rows, null, 2));
else {
  for (const r of rows) console.log(`${r.match ? "OK  " : "FAIL"} ${r.name.padEnd(16)} ${r.address}\n      chain ${r.onChain}\n      build ${r.local}`);
}
process.exit(rows.every((r) => r.match) ? 0 : 1);
