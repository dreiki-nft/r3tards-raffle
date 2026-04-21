#!/usr/bin/env node
/**
 * r3tards NFT + SBT snapshot
 * Monad mainnet — pure JSON-RPC, no dependencies
 *
 * Uses balanceOf() at snapshot block for each SBT holder wallet.
 * Fast — 892 RPC calls instead of scanning millions of blocks.
 *
 * Usage:
 *   node snapshot.js --rpc https://rpc.monad.xyz --block 69507499 --airdrop airdrop_final.csv --out snapshot_final.csv
 *
 * Ticket rules:
 *   1 r3tard NFT        = 1 ticket
 *   1 r3tard SBT        = 2 tickets  (tier 2 in airdrop_final.csv)
 *   1 Diamond Hand SBT  = 3 tickets  (tier 1 in airdrop_final.csv)
 *   certified j33t SBT  = 0 tickets  (tier 3 in airdrop_final.csv)
 *
 * SBTs are soulbound — airdrop_final.csv is permanent source of truth.
 * NFT holdings fetched via balanceOf at snapshot block.
 */

'use strict';

const https = require('https');
const http  = require('http');
const fs    = require('fs');

const NFT_ADDR = '0x200723A706de0013316E5cd8EBa2b3f53DD90c29';

const args = process.argv.slice(2);
function arg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const RPC_URL      = arg('--rpc',     'https://rpc.monad.xyz');
const BLOCK_RAW    = arg('--block',   'latest');
const AIRDROP_FILE = arg('--airdrop', 'airdrop_final.csv');
const OUT_FILE     = arg('--out',     'snapshot_final.csv');
const CONCURRENCY  = parseInt(arg('--concurrency', '20'), 10);

const BLOCK = BLOCK_RAW === 'latest' ? 'latest' : '0x' + parseInt(BLOCK_RAW).toString(16);

// ─── RPC ──────────────────────────────────────────────────────────────────────
let _id = 1;
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: _id++, method, params });
    const u    = new URL(RPC_URL);
    const mod  = u.protocol === 'https:' ? https : http;
    const req  = mod.request({
      hostname: u.hostname,
      port:     u.port || (u.protocol === 'https:' ? 443 : 80),
      path:     u.pathname + u.search,
      method:   'POST',
      headers:  { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try {
          const j = JSON.parse(data);
          if (j.error) reject(new Error(j.error.message));
          else resolve(j.result);
        } catch(e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// balanceOf(address) selector: 0x70a08231
function encodeBalanceOf(addr) {
  return '0x70a08231' + addr.replace('0x', '').toLowerCase().padStart(64, '0');
}

async function getBalance(wallet, retries = 5) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const result = await rpc('eth_call', [{
        to:   NFT_ADDR,
        data: encodeBalanceOf(wallet),
      }, BLOCK]);
      return parseInt(result, 16) || 0;
    } catch(e) {
      if (attempt === retries) {
        console.error(`\n[error] Failed to get balance for ${wallet} after ${retries} attempts: ${e.message}`);
        process.exit(1); // hard fail — never silently exclude
      }
      await new Promise(r => setTimeout(r, 500 * attempt)); // backoff
    }
  }
}

// ─── Load airdrop ─────────────────────────────────────────────────────────────
function loadAirdrop(file) {
  if (!fs.existsSync(file)) {
    console.error(`[error] ${file} not found`);
    process.exit(1);
  }

  const lines  = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/);
  const cols   = lines[0].toLowerCase().split(',');
  const wIdx   = cols.findIndex(c => c.includes('wallet') || c.includes('address'));
  const tIdx   = cols.findIndex(c => c.includes('tier'));

  if (wIdx === -1 || tIdx === -1) {
    console.error(`[error] Could not find wallet/tier columns in ${file}`);
    process.exit(1);
  }

  const wallets = [];
  for (let i = 1; i < lines.length; i++) {
    const row    = lines[i].split(',');
    const wallet = row[wIdx]?.trim().toLowerCase();
    const tier   = row[tIdx]?.trim();
    if (wallet && tier) wallets.push({ wallet, tier });
  }
  return wallets;
}

// ─── Concurrency pool ─────────────────────────────────────────────────────────
async function pool(items, fn, concurrency) {
  const results = new Array(items.length);
  let idx = 0;
  async function worker() {
    while (idx < items.length) {
      const i = idx++;
      results[i] = await fn(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker));
  return results;
}

// ─── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards snapshot — balanceOf mode    ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`RPC:          ${RPC_URL}`);
  console.log(`Snapshot block: ${BLOCK_RAW}`);
  console.log(`Airdrop file: ${AIRDROP_FILE}`);
  console.log(`Output:       ${OUT_FILE}\n`);

  // Load airdrop
  const airdrop = loadAirdrop(AIRDROP_FILE);
  console.log(`Loaded ${airdrop.length} wallets from ${AIRDROP_FILE}`);

  // Fetch NFT balances concurrently
  console.log(`\nFetching NFT balances at block ${BLOCK_RAW} (${CONCURRENCY} concurrent)...\n`);

  let done = 0;
  const balances = await pool(airdrop, async ({ wallet, tier }, i) => {
    const bal = await getBalance(wallet);
    done++;
    if (done % 50 === 0 || done === airdrop.length) {
      process.stdout.write(`\r  ${done}/${airdrop.length} wallets checked...`);
    }
    return { wallet, tier, nftBalance: bal };
  }, CONCURRENCY);

  console.log('\n');

  // Compute tickets
  const rows    = [];
  let totalWallets = 0;
  let totalTickets = 0;
  let skipped      = 0;

  for (const { wallet, tier, nftBalance } of balances) {
    // SBT tickets
    let sbtTickets = 0;
    if (tier === '1') sbtTickets = 3;      // Diamond Hand
    else if (tier === '2') sbtTickets = 2; // r3tard SBT
    else if (tier === '3') sbtTickets = 0; // certified j33t

    const nftTickets   = nftBalance;
    const totalForWallet = sbtTickets + nftTickets;

    if (totalForWallet === 0) {
      skipped++;
      continue; // j33ts with no NFTs get 0 tickets — skip
    }

    rows.push({ wallet, tier, nftBalance, sbtTickets, nftTickets, tickets: totalForWallet });
    totalWallets++;
    totalTickets += totalForWallet;
  }

  // Write CSV
  const header = 'wallet,tier,nft_balance,sbt_tickets,nft_tickets,tickets';
  const lines  = rows.map(r =>
    `${r.wallet},${r.tier},${r.nftBalance},${r.sbtTickets},${r.nftTickets},${r.tickets}`
  );
  fs.writeFileSync(OUT_FILE, [header, ...lines].join('\n'), 'utf8');

  // Summary
  console.log('══════════════════════════════════════════');
  console.log(`Wallets with tickets : ${totalWallets}`);
  console.log(`Wallets skipped (0)  : ${skipped}`);
  console.log(`Total tickets        : ${totalTickets}`);
  console.log(`Snapshot block       : ${BLOCK_RAW}`);
  console.log(`Output saved         : ${OUT_FILE}`);
  console.log('══════════════════════════════════════════\n');

  // Tier breakdown
  const d = rows.filter(r => r.tier === '1');
  const r = rows.filter(r => r.tier === '2');
  const j = rows.filter(r => r.tier === '3');
  console.log(`💎 Diamond Hand : ${d.length} wallets, ${d.reduce((s,x) => s+x.tickets,0)} tickets`);
  console.log(`🥴 r3tard SBT  : ${r.length} wallets, ${r.reduce((s,x) => s+x.tickets,0)} tickets`);
  console.log(`🐀 j33t SBT    : ${j.length} wallets, ${j.reduce((s,x) => s+x.tickets,0)} tickets`);
  console.log('');
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
