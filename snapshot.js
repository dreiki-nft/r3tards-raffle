#!/usr/bin/env node
/**
 * r3tards NFT + SBT snapshot
 * Monad mainnet — pure JSON-RPC, no dependencies
 *
 * Ticket rules:
 *   1 r3tard NFT        = 1 ticket  (ALL NFT holders included)
 *   Diamond Hand SBT    = +3 tickets (tier 1 in airdrop_final.csv)
 *   r3tard SBT          = +2 tickets (tier 2 in airdrop_final.csv)
 *   certified j33t SBT  = +0 tickets (tier 3)
 *   Tickets stack.
 *
 * Method: ownerOf(tokenId) for each tokenId 1..totalSupply
 * This finds ALL current holders regardless of SBT status.
 *
 * Usage:
 *   node snapshot.js --rpc https://rpc.monad.xyz --block 69612284 \
 *     --supply 1033 --airdrop airdrop_final.csv --out snapshot_final.csv
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
const TOTAL_SUPPLY = parseInt(arg('--supply', '1033'), 10);
const AIRDROP_FILE = arg('--airdrop', 'airdrop_final.csv');
const OUT_FILE     = arg('--out',     'snapshot_final.csv');

const BLOCK_HEX = BLOCK_RAW === 'latest' ? 'latest' : '0x' + parseInt(BLOCK_RAW).toString(16);

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

// ownerOf(uint256) selector: 0x6352211e
function encodeOwnerOf(tokenId) {
  return '0x6352211e' + tokenId.toString(16).padStart(64, '0');
}

async function getOwner(tokenId, retries = 5) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const result = await rpc('eth_call', [{
        to:   NFT_ADDR,
        data: encodeOwnerOf(tokenId),
      }, BLOCK_HEX]);
      if (!result || result === '0x') return null;
      return '0x' + result.slice(26).toLowerCase();
    } catch(e) {
      if (attempt === retries) {
        console.error(`\n[error] ownerOf(${tokenId}) failed after ${retries} attempts: ${e.message}`);
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
  console.log('║     r3tards snapshot — ownerOf mode      ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`RPC:            ${RPC_URL}`);
  console.log(`Snapshot block: ${BLOCK_RAW}`);
  console.log(`Total supply:   ${TOTAL_SUPPLY}`);
  console.log(`Airdrop file:   ${AIRDROP_FILE}`);
  console.log(`Output:         ${OUT_FILE}\n`);

  // Step 1: Load SBT airdrop
  console.log('Step 1: Loading SBT airdrop data...');
  const airdrop = loadAirdrop(AIRDROP_FILE);
  console.log(`  ${airdrop.size} SBT holders loaded\n`);

  // Step 2: ownerOf for each tokenId 1..totalSupply
  console.log(`Step 2: Fetching owner of each tokenId (1–${TOTAL_SUPPLY}) sequentially...`);
  const nftCounts = new Map(); // wallet → nft count

  for (let tokenId = 1; tokenId <= TOTAL_SUPPLY; tokenId++) {
    const owner = await getOwner(tokenId);
    if (owner && owner !== '0x' + '0'.repeat(40)) {
      nftCounts.set(owner, (nftCounts.get(owner) || 0) + 1);
    }
    if (tokenId % 50 === 0 || tokenId === TOTAL_SUPPLY) {
      process.stdout.write(`\r  ${tokenId}/${TOTAL_SUPPLY} tokens checked (${nftCounts.size} unique holders)...`);
    }
  }
  console.log(`\n  ${nftCounts.size} unique NFT holders found\n`);

  // Step 3: Compute tickets
  console.log('Step 3: Computing tickets...');
  const rows = [];
  let totalTickets = 0;
  let skipped = 0;

  // All NFT holders
  for (const [wallet, nftBalance] of nftCounts) {
    const tier = airdrop.get(wallet) || '0';
    let sbtTickets = 0;
    if (tier === '1') sbtTickets = 3;
    else if (tier === '2') sbtTickets = 2;

    const totalForWallet = sbtTickets + nftBalance;
    rows.push({ wallet, tier, nftBalance, sbtTickets, nftTickets: nftBalance, tickets: totalForWallet });
    totalTickets += totalForWallet;
  }

  // SBT holders with 0 NFTs (Diamond Hand / r3tard SBT but no NFT)
  for (const [wallet, tier] of airdrop) {
    if (nftCounts.has(wallet)) continue; // already handled
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
