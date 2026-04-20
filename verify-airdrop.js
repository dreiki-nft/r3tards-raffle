#!/usr/bin/env node
/**
 * verify-airdrop.js
 * Verifies airdrop_final.csv against:
 *   1. Onchain SBT holdings — every wallet in CSV must hold an SBT
 *   2. Onchain metadata — tier in CSV must match tokenURI trait
 *
 * Usage:
 *   node verify-airdrop.js \
 *     --rpc https://rpc.monad.xyz \
 *     --airdrop airdrop_final.csv \
 *     --tokens sbt_tokens.csv
 *
 * Output:
 *   Console report + verify_report.csv
 */

'use strict';

const https = require('https');
const http  = require('http');
const fs    = require('fs');

const SBT_CONTRACT = '0xFC8fD04a3887Fc7936d121534F61f30c3d88c38D';

const args = process.argv.slice(2);
function arg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const RPC_URL      = arg('--rpc',     'https://rpc.monad.xyz');
const AIRDROP_FILE = arg('--airdrop', 'airdrop_final.csv');
const TOKENS_FILE  = arg('--tokens',  'sbt_tokens.csv');
const OUT          = arg('--out',     'verify_report.csv');

// ─── Tier mappings ────────────────────────────────────────────────────────────
// Maps tier number in airdrop_final.csv to expected OpenSea trait value
const TIER_NAMES = {
  '1': 'Diamond Hand',
  '2': 'r3tard',
  '3': 'certified j33t',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────
let _reqId = 1;
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: _reqId++, method, params });
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

// ABI encode: balanceOf(address) → bytes
function encodeBalanceOf(addr) {
  const selector = '70a08231'; // balanceOf(address)
  const padded   = addr.replace('0x', '').toLowerCase().padStart(64, '0');
  return '0x' + selector + padded;
}

// ABI encode: tokenURI(uint256) → bytes
function encodeTokenURI(tokenId) {
  const selector = 'c87b56dd'; // tokenURI(uint256)
  const padded   = BigInt(tokenId).toString(16).padStart(64, '0');
  return '0x' + selector + padded;
}

// Decode string return from tokenURI call
function decodeString(hex) {
  try {
    const data   = hex.startsWith('0x') ? hex.slice(2) : hex;
    const offset = parseInt(data.slice(0, 64), 16) * 2;
    const length = parseInt(data.slice(offset, offset + 64), 16);
    const strHex = data.slice(offset + 64, offset + 64 + length * 2);
    return Buffer.from(strHex, 'hex').toString('utf8');
  } catch(e) {
    return null;
  }
}

function fetchIPFS(uri) {
  return new Promise((resolve, reject) => {
    // Convert ipfs:// to https gateway
    const url = uri.replace('ipfs://', 'https://ipfs.io/ipfs/');
    const mod  = url.startsWith('https') ? https : http;
    const req  = mod.get(url, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch(e) { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.setTimeout(8000, () => { req.destroy(); resolve(null); });
  });
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ─── Load files ───────────────────────────────────────────────────────────────
function loadAirdrop(file) {
  const lines  = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/);
  const cols   = lines[0].toLowerCase().split(',');
  const wIdx   = cols.findIndex(c => c.includes('wallet') || c.includes('address'));
  const tIdx   = cols.findIndex(c => c.includes('tier'));
  const result = new Map();
  for (let i = 1; i < lines.length; i++) {
    const row = lines[i].split(',');
    const w   = row[wIdx]?.trim().toLowerCase();
    const t   = row[tIdx]?.trim();
    if (w && t) result.set(w, t);
  }
  return result;
}

function loadTokens(file) {
  // Returns Map<wallet, tokenId>
  const lines  = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/);
  const cols   = lines[0].toLowerCase().split(',');
  const tidIdx = cols.findIndex(c => c.includes('tokenid'));
  const ownIdx = cols.findIndex(c => c.includes('owner') || c.includes('minted_to'));
  const result = new Map();
  for (let i = 1; i < lines.length; i++) {
    const row    = lines[i].split(',');
    const owner  = row[ownIdx]?.trim().toLowerCase();
    const tokenId = row[tidIdx]?.trim();
    if (owner && tokenId) result.set(owner, parseInt(tokenId));
  }
  return result;
}

// ─── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards SBT — airdrop verification   ║');
  console.log('╚══════════════════════════════════════════╝\n');

  // Load files
  if (!fs.existsSync(AIRDROP_FILE)) { console.error(`[error] ${AIRDROP_FILE} not found`); process.exit(1); }
  if (!fs.existsSync(TOKENS_FILE))  { console.error(`[error] ${TOKENS_FILE} not found`);  process.exit(1); }

  const airdrop = loadAirdrop(AIRDROP_FILE);
  const tokens  = loadTokens(TOKENS_FILE);

  console.log(`Airdrop wallets : ${airdrop.size}`);
  console.log(`SBT tokens file : ${tokens.size} entries\n`);

  const report = [];
  let passCount = 0, failCount = 0, warnCount = 0;
  let i = 0;

  for (const [wallet, tier] of airdrop) {
    i++;
    process.stdout.write(`  [${i}/${airdrop.size}] ${wallet.slice(0,10)}... `);

    const row = { wallet, tier_csv: tier, tier_name_csv: TIER_NAMES[tier] || '?', balance: 0, tokenId: '?', tier_metadata: '?', balance_ok: false, metadata_ok: false, status: '' };

    // ── Check 1: onchain balance ─────────────────────────────────────────────
    try {
      const balHex = await rpc('eth_call', [{
        to:   SBT_CONTRACT,
        data: encodeBalanceOf(wallet),
      }, 'latest']);
      row.balance    = parseInt(balHex, 16);
      row.balance_ok = row.balance > 0;
    } catch(e) {
      row.balance_ok = false;
    }

    // ── Check 2: tokenURI metadata tier ──────────────────────────────────────
    const tokenId = tokens.get(wallet);
    if (tokenId !== undefined) {
      row.tokenId = tokenId;
      try {
        const uriHex = await rpc('eth_call', [{
          to:   SBT_CONTRACT,
          data: encodeTokenURI(tokenId),
        }, 'latest']);
        const uri = decodeString(uriHex);
        if (uri) {
          const metadata = await fetchIPFS(uri);
          if (metadata) {
            const tierTrait = (metadata.attributes || metadata.traits || [])
              .find(a => a.trait_type?.toLowerCase() === 'tier' || a.trait_type?.toLowerCase() === 'type');
            row.tier_metadata = tierTrait ? tierTrait.value : 'NOT FOUND';
            row.metadata_ok   = row.tier_metadata === TIER_NAMES[tier];
          } else {
            row.tier_metadata = 'IPFS TIMEOUT';
          }
        }
      } catch(e) {
        row.tier_metadata = 'ERROR';
      }
    } else {
      row.tier_metadata = 'NOT IN TOKENS FILE';
    }

    // ── Status ────────────────────────────────────────────────────────────────
    if (!row.balance_ok) {
      row.status = '❌ NO SBT ONCHAIN';
      failCount++;
    } else if (row.tier_metadata === 'IPFS TIMEOUT' || row.tier_metadata === 'NOT IN TOKENS FILE') {
      row.status = '⚠️  METADATA UNAVAILABLE';
      warnCount++;
    } else if (!row.metadata_ok) {
      row.status = `❌ TIER MISMATCH (csv=${row.tier_name_csv}, metadata=${row.tier_metadata})`;
      failCount++;
    } else {
      row.status = '✅ OK';
      passCount++;
    }

    process.stdout.write(`bal=${row.balance} | tier=${row.tier_metadata} | ${row.status}\n`);
    report.push(row);

    // Small delay to avoid hammering RPC + IPFS
    await sleep(100);
  }

  // ── Summary ──────────────────────────────────────────────────────────────────
  console.log('\n══════════════════════════════════════════');
  console.log(`✅ Passed          : ${passCount}`);
  console.log(`⚠️  Warnings        : ${warnCount} (IPFS timeouts — not critical)`);
  console.log(`❌ Failed           : ${failCount}`);
  console.log('══════════════════════════════════════════\n');

  if (failCount > 0) {
    console.log('FAILED wallets:');
    report.filter(r => r.status.startsWith('❌')).forEach(r => {
      console.log(`  ${r.wallet} — ${r.status}`);
    });
    console.log('');
  }

  // ── Write report CSV ─────────────────────────────────────────────────────────
  const header = 'wallet,tier_csv,tier_name_csv,balance,tokenId,tier_metadata,balance_ok,metadata_ok,status';
  const lines  = report.map(r =>
    `${r.wallet},${r.tier_csv},${r.tier_name_csv},${r.balance},${r.tokenId},${r.tier_metadata},${r.balance_ok},${r.metadata_ok},"${r.status}"`
  );
  fs.writeFileSync(OUT, [header, ...lines].join('\n'), 'utf8');
  console.log(`Report saved → ${OUT}\n`);
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
