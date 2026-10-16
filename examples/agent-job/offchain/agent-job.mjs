#!/usr/bin/env node
// The off-chain half of examples/agent-job: the same job seen from the Taifoon coordination API (no dependencies, Node 18+).
//   node offchain/agent-job.mjs <AgentJob address> <jobId string> [--rpc <url>] [--key <tfr_ key>]
// 1. the fee rule the contract uses, from the live quote (GET /v1/fees/quote)
// 2. a free API key if you have none (POST /v1/register) — needed for the stream
// 3. the job on chain (AgentJob.jobs) and Jev's decision on it (the decision log), over JSON-RPC
// 4. the job's envelopes on the coord stream (GET /v1/pipe/stream?order_keys=…), for a few seconds
const API = process.env.TAIFOON_API ?? 'https://coord.taifoon.dev';
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const [jobAddr, jobName] = args;
if (!jobAddr || !jobName) { console.error('usage: node offchain/agent-job.mjs <AgentJob address> <jobId string> [--rpc url] [--key tfr_…]'); process.exit(2); }
const rpcUrl = opt('--rpc', 'https://rpc.taifoon.dev');
let key = opt('--key', process.env.TAIFOON_KEY);
const { createHash } = await import('node:crypto');

const rpc = async (method, params) => {
  const r = await fetch(rpcUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json(); if (j.error) throw new Error(`${method}: ${j.error.message}`); return j.result;
};
const keccak = async (hexOrText, isText) => {
  // keccak256 through the node itself (web3_sha3), so this file needs no library
  const hex = isText ? `0x${Buffer.from(hexOrText, 'utf8').toString('hex')}` : hexOrText;
  return rpc('web3_sha3', [hex]);
};
const word = (h) => h.replace(/^0x/, '').padStart(64, '0');

// 1. the fee rule
const q = await (await fetch(`${API}/v1/fees/quote?price=10`)).json();
console.log(`1. fee quote on ${q.chainId} for a 10 USDC seller price: fee ${Number(q.fee) / 1e6} USDC (floor ${Number(q.floor) / 1e6})`);

// 2. a free key
if (!key) {
  const r = await fetch(`${API}/v1/register`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  const j = await r.json().catch(() => ({}));
  key = j.key ?? j.api_key ?? j.keys?.live ?? null;
  console.log(`2. free key: ${key ? `${key.slice(0, 12)}… (keep it; it is shown once)` : `not issued (${r.status} ${j.code ?? ''}: ${j.error ?? 'one free key per caller per day'})`}`);
} else console.log('2. using your key');

// 3. the job and Jev's decision, on chain
const jobId = await keccak(jobName, true);
const sel = async (sig) => (await keccak(sig, true)).slice(0, 10);
const jobsSel = await sel('jobs(bytes32)');
const raw = await rpc('eth_call', [{ to: jobAddr, data: `${jobsSel}${word(jobId)}` }, 'latest']);
const state = parseInt(raw.slice(2 + 64 * 9, 2 + 64 * 10), 16);
console.log(`3. job ${jobName} on ${jobAddr}: state ${state} (1 posted, 2 paid, 3 refunded)`);
const logAddr = `0x${(await rpc('eth_call', [{ to: jobAddr, data: await sel('decisionLog()') }, 'latest'])).slice(-40)}`;
const chainId = parseInt(await rpc('eth_chainId', []), 16);
const subject = await rpc('eth_call', [{ to: logAddr, data: `${await sel('subjectOf(uint256,address,bytes32)')}${word(chainId.toString(16))}${word(jobAddr)}${word(jobId)}` }, 'latest']);
const count = parseInt(await rpc('eth_call', [{ to: logAddr, data: `${await sel('count(bytes32)')}${word(subject)}` }, 'latest']), 16);
console.log(`   Jev decisions on it in the log ${logAddr}: ${count}`);

// 4. the stream
if (key) {
  const okh = `sale:${chainId}:${jobName}`;
  const ac = new AbortController(); setTimeout(() => ac.abort(), 5000);
  try {
    const r = await fetch(`${API}/v1/pipe/stream?order_keys=${encodeURIComponent(okh)}`, { headers: { 'x-api-key': key }, signal: ac.signal });
    console.log(`4. stream for ${okh}: HTTP ${r.status} (events of this order arrive here as the pipe sees them)`);
  } catch { console.log('4. stream: no event in 5 s (the order has no envelope yet)'); }
} else console.log('4. stream: needs a key (step 2)');
