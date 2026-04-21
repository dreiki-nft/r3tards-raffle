#!/usr/bin/env node
/**
 * r3tards NFT + SBT snapshot
 * Monad mainnet — pure JSON-RPC, no dependencies
 *
 * Ticket rules:
 *   1 r3tard NFT        = 1 ticket  (ALL NFT holders included)
 *   1 r3tard SBT        = 2 tickets (tier 2 in airdrop_final.csv)
 *   1 Diamond Hand SBT  = 3 tickets (tier 1 in airdrop_final.csv)
 *   certified j33t SBT  = 0 tickets (tier 3 in airdrop_final.csv)
 *   Tickets stack.
 *
 * Steps:
 *   1. Scan Transfer events to find ALL current NFT holders
 *   2. Load airdrop_final.csv for SBT bonuses
 *   3. Merge — every NFT holder gets tickets, SBT holders get bonuses on top
 *
 * Usage:
 *   node snapshot.js --rpc https://rpc.monad.xyz --block 69612284 \
 *     --from 66677485 --airdrop airdrop_final.csv --out snapshot_final.csv
 */

'use strict';

const https = require('https');
const http  = require('http');
const fs    = require('fs');

const NFT_ADDR     = '0x200723A706de0013316E5cd8EBa2b3f53DD90c29';
const TRANSFER_SIG = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

const args = process.argv.slice(2);
function arg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const RPC_URL      = arg('--rpc',     'https://rpc.monad.xyz');
const BLOCK_RAW    = arg('--block',   'latest');
const FROM_BLOCK   = arg('--from',    '66677485'); // r3tards deployment block
const AIRDROP_FILE = arg('--airdrop', 'airdrop_final.csv');
const OUT_FILE     = arg('--out',     'snapshot_final.csv');
const CHUNK_SIZE   = parseInt(arg('--chunk', '2000'), 10);

const BLOCK_HEX = BLOCK_RAW === 'latest' ? 'latest' : '0x' + parseInt(BLOCK_RAW).toString(16);
const FROM_HEX  = '0x' + parseInt(FROM_BLOCK).toString(16);

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

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ─── Fetch Transfer logs with chunking ────────────────────────────────────────
async function fetchAllTransfers(fromBlock, toBlock) {
  const transfers = [];
  let from = parseInt(fromBlock, 16);
  const to = toBlock === 'latest'
    ? parseInt(await rpc('eth_blockNumber', []), 16)
    : parseInt(toBlock, 16);

  let chunk = CHUNK_SIZE;

  while (from <= to) {
    const end = Math.min(from + chunk - 1, to);
    const fromHex = '0x' + from.toString(16);
    const endHex  = '0x' + end.toString(16);

    try {
      process.stdout.write(`\r  scanning blocks ${from}–${end}...          `);
      const logs = await rpc('eth_getLogs', [{
        address:   NFT_ADDR,
        topics:    [TRANSFER_SIG],
        fromBlock: fromHex,
        toBlock:   endHex,
      }]);

      for (const log of logs) {
        const from_addr = '0x' + log.topics[1].slice(26).toLowerCase();
        const to_addr   = '0x' + log.topics[2].slice(26).toLowerCase();
        const tokenId   = parseInt(log.topics[3], 16);
        transfers.push({ from: from_addr, to: to_addr, tokenId });
      }

      from = end + 1;
      chunk = Math.min(chunk * 2, CHUNK_SIZE); // grow back after success
    } catch(e) {
      if (e.message.includes('range') || e.message.includes('limit') || e.message.includes('too large')) {
        chunk = Math.max(Math.floor(chunk / 2), 1);
        process.stdout.write(`\n  [warn] range too large, halving chunk to ${chunk}\n`);
      } else {
        throw e;
      }
    }
  }

  console.log(`\n  found ${transfers.length} transfer events`);
  return transfers;
}

// ─── Build current holders from transfer history ──────────────────────────────
function buildHolders(transfers) {
  const holders = new Map(); // tokenId → owner

  for (const { from, to, tokenId } of transfers) {
    if (from === '0x' + '0'.repeat(40)) {
      // mint
      holders.set(tokenId, to);
    } else {
      holders.set(tokenId, to);
    }
  }

  // Count per wallet
  const counts = new Map();
  for (const owner of holders.values()) {
    counts.set(owner, (counts.get(owner) || 0) + 1);
  }

  return counts; // Map<wallet, nftCount>
}

// ─── balanceOf verification ───────────────────────────────────────────────────
async function verifyBalance(wallet) {
  const data = '0x70a08231' + wallet.replace('0x', '').padStart(64, '0');
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const result = await rpc('eth_call', [{ to: NFT_ADDR, data }, BLOCK_HEX]);
      if (!result || result === '0x') return 0;
      const bal = parseInt(result, 16);
      return isNaN(bal) ? 0 : bal;
    } catch(e) {
      if (attempt === 5) {
        console.error(`\n[error] balanceOf failed for ${wallet}: ${e.message}`);
        process.exit(1);
      }
      await sleep(500 * attempt);
    }
  }
}

// ─── Load airdrop ─────────────────────────────────────────────────────────────
function loadAirdrop(file) {
  if (!fs.existsSync(file)) {
    console.error(`[error] ${file} not found`);
    process.exit(1);
  }
  const lines = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/);
  const cols  = lines[0].toLowerCase().split(',');
  const wIdx  = cols.findIndex(c => c.includes('wallet') || c.includes('address'));
  const tIdx  = cols.findIndex(c => c.includes('tier'));

  const map = new Map();
  for (let i = 1; i < lines.length; i++) {
    const row    = lines[i].split(',');
    const wallet = row[wIdx]?.trim().toLowerCase();
    const tier   = row[tIdx]?.trim();
    if (wallet && tier) map.set(wallet, tier);
  }
  return map;
}

// ─── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards snapshot — full holder scan  ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`RPC:            ${RPC_URL}`);
  console.log(`Snapshot block: ${BLOCK_RAW}`);
  console.log(`From block:     ${FROM_BLOCK}`);
  console.log(`Airdrop file:   ${AIRDROP_FILE}`);
  console.log(`Output:         ${OUT_FILE}\n`);

  // Step 1: Scan Transfer events
  console.log('Step 1: Scanning Transfer events...');
  const transfers = await fetchAllTransfers(FROM_HEX, BLOCK_HEX);

  // Step 2: Build holder list from transfers
  console.log('\nStep 2: Building holder list from transfers...');
  const transferHolders = buildHolders(transfers);
  console.log(`  ${transferHolders.size} unique holders from transfer history`);

  // Step 3: Verify each holder's balance via balanceOf (sequential, no mixing)
  console.log('\nStep 3: Verifying balances via balanceOf (sequential)...');
  const holderList = [...transferHolders.keys()];
  const verifiedHolders = new Map();
  let checked = 0;

  for (const wallet of holderList) {
    const bal = await verifyBalance(wallet);
    if (bal > 0) verifiedHolders.set(wallet, bal);
    checked++;
    if (checked % 50 === 0 || checked === holderList.length) {
      process.stdout.write(`\r  ${checked}/${holderList.length} verified (${verifiedHolders.size} with balance)...`);
    }
  }
  console.log(`\n  ${verifiedHolders.size} wallets with NFTs at snapshot block`);

  // Step 4: Load SBT airdrop
  console.log('\nStep 4: Loading SBT airdrop data...');
  const airdrop = loadAirdrop(AIRDROP_FILE);
  console.log(`  ${airdrop.size} SBT holders loaded`);

  // Step 5: Merge — all NFT holders get tickets, SBT holders get bonus
  console.log('\nStep 5: Computing tickets...');
  const rows = [];
  let totalTickets = 0;
  let skipped = 0;

  for (const [wallet, nftBalance] of verifiedHolders) {
    const tier = airdrop.get(wallet) || '0'; // '0' = no SBT

    let sbtTickets = 0;
    if (tier === '1') sbtTickets = 3;
    else if (tier === '2') sbtTickets = 2;
    // tier 3 (j33t) = 0, tier 0 (no SBT) = 0

    const nftTickets     = nftBalance;
    const totalForWallet = sbtTickets + nftTickets;

    if (totalForWallet === 0) { skipped++; continue; }

    rows.push({ wallet, tier, nftBalance, sbtTickets, nftTickets, tickets: totalForWallet });
    totalTickets += totalForWallet;
  }

  // Also add SBT holders who somehow have 0 NFTs but positive SBT tickets
  // (j33ts with no NFTs are already skipped, Diamond/r3tard with no NFTs get SBT tickets)
  for (const [wallet, tier] of airdrop) {
    if (verifiedHolders.has(wallet)) continue; // already handled above

    let sbtTickets = 0;
    if (tier === '1') sbtTickets = 3;
    else if (tier === '2') sbtTickets = 2;

    if (sbtTickets === 0) { skipped++; continue; }

    rows.push({ wallet, tier, nftBalance: 0, sbtTickets, nftTickets: 0, tickets: sbtTickets });
    totalTickets += sbtTickets;
  }

  // Write CSV
  const header = 'wallet,tier,nft_balance,sbt_tickets,nft_tickets,tickets';
  const lines  = rows.map(r =>
    `${r.wallet},${r.tier},${r.nftBalance},${r.sbtTickets},${r.nftTickets},${r.tickets}`
  );
  fs.writeFileSync(OUT_FILE, [header, ...lines].join('\n'), 'utf8');

  // Summary
  console.log('\n══════════════════════════════════════════');
  console.log(`Wallets with tickets : ${rows.length}`);
  console.log(`Wallets skipped (0)  : ${skipped}`);
  console.log(`Total tickets        : ${totalTickets}`);
  console.log(`Snapshot block       : ${BLOCK_RAW}`);
  console.log(`Output saved         : ${OUT_FILE}`);
  console.log('══════════════════════════════════════════\n');

  const d = rows.filter(r => r.tier === '1');
  const rb = rows.filter(r => r.tier === '2');
  const j = rows.filter(r => r.tier === '3');
  const n = rows.filter(r => r.tier === '0');
  console.log(`💎 Diamond Hand  : ${d.length} wallets, ${d.reduce((s,x)=>s+x.tickets,0)} tickets`);
  console.log(`🥴 r3tard SBT   : ${rb.length} wallets, ${rb.reduce((s,x)=>s+x.tickets,0)} tickets`);
  console.log(`🐀 j33t SBT     : ${j.length} wallets, ${j.reduce((s,x)=>s+x.tickets,0)} tickets`);
  console.log(`🖼️  NFT only      : ${n.length} wallets, ${n.reduce((s,x)=>s+x.tickets,0)} tickets`);
  console.log('');
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
