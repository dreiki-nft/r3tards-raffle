#!/usr/bin/env node
/**
 * r3tards NFT + SBT snapshot
 * Monad mainnet — pure JSON-RPC, no dependencies
 *
 * Usage:
 *   node snapshot.js [--rpc <url>] [--from <block>] [--to <block>] [--airdrop <file>] [--out <file.csv>] [--chunk <size>]
 *
 * Defaults:
 *   --rpc      https://rpc.monad.xyz
 *   --from     0
 *   --to       latest
 *   --airdrop  airdrop_final.csv   (your tier list — source of truth for SBT tiers)
 *   --out      snapshot_<block>.csv
 *   --chunk    10000
 *
 * Ticket rules:
 *   1 r3tard NFT        = 1 ticket
 *   1 r3tard SBT        = 2 tickets  (tier 2 in airdrop_final.csv)
 *   1 diamond Hand SBT  = 3 tickets  (tier 1 in airdrop_final.csv)
 *   certified j33t SBT  = 0 tickets  (tier 3 in airdrop_final.csv)
 *
 * SBTs are soulbound — airdrop_final.csv is permanent source of truth.
 * Only NFT holdings are fetched via RPC (transferable, need live snapshot).
 */

'use strict';

const https = require('https');
const http  = require('http');
const fs    = require('fs');

// ─── Contract addresses ───────────────────────────────────────────────────────
const NFT_ADDR  = '0x200723A706de0013316E5cd8EBa2b3f53DD90c29';
const TRANSFER  = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

// ─── CLI args ─────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
function arg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const RPC_URL      = arg('--rpc',      'https://rpc.monad.xyz');
const FROM_RAW     = arg('--from',     '0');
const TO_RAW       = arg('--to',       'latest');
const AIRDROP_FILE = arg('--airdrop',  'airdrop_final.csv');
const OUT_ARG      = arg('--out',      null);
const CHUNK        = parseInt(arg('--chunk', '10000'), 10);

// ─── Helpers ──────────────────────────────────────────────────────────────────
const toHex    = n => '0x' + BigInt(n).toString(16);
const fromHex  = s => parseInt(s, 16);
const shortAddr = a => a.slice(0, 6) + '...' + a.slice(-4);

// ─── Load airdrop tier list ───────────────────────────────────────────────────
function loadAirdrop(file) {
  if (!fs.existsSync(file)) {
    console.error(`[error] Airdrop file not found: ${file}`);
    console.error(`        Run with --airdrop <path/to/airdrop_final.csv>`);
    process.exit(1);
  }

  const lines  = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/);
  const header = lines[0].toLowerCase();

  // Detect column positions
  const cols   = header.split(',');
  const wIdx   = cols.findIndex(c => c.includes('wallet') || c.includes('address'));
  const tIdx   = cols.findIndex(c => c.includes('tier') || c.includes('type') || c.includes('rank'));

  if (wIdx === -1 || tIdx === -1) {
    console.error(`[error] Could not find wallet/tier columns in ${file}`);
    console.error(`        Expected columns: wallet, tier`);
    process.exit(1);
  }

  const diamond = new Set(); // tier 1 — 3 tickets
  const r3tard  = new Set(); // tier 2 — 2 tickets
  const j33t    = new Set(); // tier 3 — 0 tickets

  for (let i = 1; i < lines.length; i++) {
    const row    = lines[i].split(',');
    const wallet = row[wIdx]?.trim().toLowerCase();
    const tier   = row[tIdx]?.trim();
    if (!wallet || !tier) continue;

    if (tier === '1')        diamond.add(wallet);
    else if (tier === '2')   r3tard.add(wallet);
    else if (tier === '3')   j33t.add(wallet);
  }

  return { diamond, r3tard, j33t };
}

// ─── RPC ──────────────────────────────────────────────────────────────────────
let _reqId = 1;
function rpc(url, method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: _reqId++, method, params });
    const u    = new URL(url);
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
          if (j.error) reject(new Error(`RPC error: ${j.error.message}`));
          else resolve(j.result);
        } catch(e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

async function getBlockNumber() {
  return fromHex(await rpc(RPC_URL, 'eth_blockNumber', []));
}

async function getLogsChunked(address, fromBlock, toBlock) {
  const all = [];
  let from  = fromBlock;
  while (from <= toBlock) {
    const to = Math.min(from + CHUNK - 1, toBlock);
    process.stdout.write(`  fetching logs ${address.slice(0,10)}... blocks ${from}–${to} `);
    try {
      const logs = await rpc(RPC_URL, 'eth_getLogs', [{
        address,
        topics:    [TRANSFER],
        fromBlock: toHex(from),
        toBlock:   toHex(to),
      }]);
      process.stdout.write(`→ ${logs.length} events\n`);
      all.push(...logs);
    } catch(e) {
      process.stdout.write(`\n`);
      if (e.message.includes('range') || e.message.includes('limit') || e.message.includes('too many')) {
        console.warn(`  [warn] range too large, halving chunk size and retrying...`);
        const mid   = Math.floor((from + to) / 2);
        const left  = await getLogsChunked(address, from, mid);
        const right = await getLogsChunked(address, mid + 1, to);
        all.push(...left, ...right);
        from = to + 1;
        continue;
      }
      throw e;
    }
    from = to + 1;
  }
  return all;
}

// ─── NFT ownership ────────────────────────────────────────────────────────────
function buildNFTOwnership(logs) {
  const counts = new Map();
  for (const evt of logs) {
    const from = ('0x' + evt.topics[1].slice(26)).toLowerCase();
    const to   = ('0x' + evt.topics[2].slice(26)).toLowerCase();
    if (from !== ZERO_ADDR) counts.set(from, Math.max(0, (counts.get(from) || 0) - 1));
    if (to   !== ZERO_ADDR) counts.set(to,   (counts.get(to)   || 0) + 1);
  }
  for (const [k, v] of counts) if (v <= 0) counts.delete(k);
  return counts;
}

// ─── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║       r3tards snapshot — monad           ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`RPC:          ${RPC_URL}`);
  console.log(`NFT:          ${NFT_ADDR}`);
  console.log(`Airdrop file: ${AIRDROP_FILE}`);

  // ── Load SBT tiers from airdrop_final.csv ─────────────────────────────────
  const { diamond, r3tard, j33t } = loadAirdrop(AIRDROP_FILE);
  console.log(`\nSBT tiers loaded from ${AIRDROP_FILE}:`);
  console.log(`  💎 Diamond Hand : ${diamond.size} wallets (3 tickets each)`);
  console.log(`  🥴 r3tard       : ${r3tard.size}  wallets (2 tickets each)`);
  console.log(`  🐀 j33t         : ${j33t.size}   wallets (0 tickets)`);

  // ── Resolve block range ────────────────────────────────────────────────────
  const latestBlock = await getBlockNumber();
  const fromBlock   = FROM_RAW === '0' ? 0 : parseInt(FROM_RAW, 10);
  const toBlock     = TO_RAW === 'latest' ? latestBlock : parseInt(TO_RAW, 10);

  console.log(`\nSnapshot block: ${toBlock} (latest: ${latestBlock})`);
  console.log(`Block range:    ${fromBlock} → ${toBlock}\n`);

  // ── Fetch NFT Transfer events ──────────────────────────────────────────────
  console.log('Fetching NFT Transfer events...');
  const nftLogs = await getLogsChunked(NFT_ADDR, fromBlock, toBlock);

  // ── Build NFT ownership ────────────────────────────────────────────────────
  console.log('\nBuilding NFT ownership map...');
  const nftOwners = buildNFTOwnership(nftLogs);
  console.log(`NFT holders: ${nftOwners.size}`);

  // ── Merge all eligible wallets ─────────────────────────────────────────────
  const allWallets = new Set([
    ...nftOwners.keys(),
    ...diamond,
    ...r3tard,
    // j33t intentionally excluded — 0 tickets
  ]);

  console.log(`\nUnique eligible wallets: ${allWallets.size}`);

  // ── Build rows ─────────────────────────────────────────────────────────────
  const rows = [];
  for (const wallet of allWallets) {
    const nft        = nftOwners.get(wallet) || 0;
    const diamondSBT = diamond.has(wallet) ? 1 : 0;
    const r3tardSBT  = r3tard.has(wallet)  ? 1 : 0;
    const tickets    = nft * 1 + r3tardSBT * 2 + diamondSBT * 3;
    if (tickets === 0) continue;
    rows.push({ wallet, nft, r3tard_sbt: r3tardSBT, diamond_sbt: diamondSBT, tickets });
  }

  rows.sort((a, b) => b.tickets - a.tickets);

  // ── Stats ──────────────────────────────────────────────────────────────────
  const totalTickets = rows.reduce((s, r) => s + r.tickets, 0);
  const totalNFT     = rows.reduce((s, r) => s + r.nft, 0);
  const totalR3tard  = rows.reduce((s, r) => s + r.r3tard_sbt, 0);
  const totalDia     = rows.reduce((s, r) => s + r.diamond_sbt, 0);

  console.log('\n──────────────────────────────────────────');
  console.log(`Eligible wallets : ${rows.length}`);
  console.log(`Total tickets    : ${totalTickets}`);
  console.log(`  NFT tickets    : ${totalNFT}     (${totalNFT} NFTs × 1)`);
  console.log(`  r3tard SBTs    : ${totalR3tard * 2} (${totalR3tard} SBTs × 2)`);
  console.log(`  diamond SBTs   : ${totalDia * 3}   (${totalDia} SBTs × 3)`);
  console.log('──────────────────────────────────────────\n');

  // ── Top 10 preview ─────────────────────────────────────────────────────────
  console.log('Top 10 by tickets:');
  console.log('  Rank  Wallet          NFT  r3SBT  diaSBT  Tickets');
  rows.slice(0, 10).forEach((r, i) => {
    const rank = String(i + 1).padStart(4);
    const w    = shortAddr(r.wallet).padEnd(14);
    console.log(`  ${rank}  ${w}  ${String(r.nft).padStart(3)}  ${String(r.r3tard_sbt).padStart(5)}  ${String(r.diamond_sbt).padStart(6)}  ${r.tickets}`);
  });

  // ── Write CSV ──────────────────────────────────────────────────────────────
  const outFile = OUT_ARG || `snapshot_${toBlock}.csv`;
  const header  = 'wallet,r3tard_nft,r3tard_sbt,diamond_sbt,tickets';
  const lines   = rows.map(r =>
    `${r.wallet},${r.nft},${r.r3tard_sbt},${r.diamond_sbt},${r.tickets}`
  );
  fs.writeFileSync(outFile, [header, ...lines].join('\n'), 'utf8');

  console.log(`\nSnapshot saved → ${outFile}`);
  console.log(`Snapshot block  → ${toBlock}`);
  console.log(`Git this repo to pin the snapshot hash.\n`);
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
