#!/usr/bin/env node
/**
 * load-snapshot.js
 * Reads snapshot CSV and calls loadTickets() on the deployed R3tardsRaffle contract
 *
 * Usage:
 *   node load-snapshot.js \
 *     --rpc https://rpc.monad.xyz \
 *     --contract <RAFFLE_CONTRACT_ADDRESS> \
 *     --csv snapshot_<block>.csv \
 *     --block <snapshotBlock> \
 *     --key <PRIVATE_KEY>
 */

'use strict';

const https  = require('https');
const http   = require('http');
const fs     = require('fs');

const args = process.argv.slice(2);
function arg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const RPC_URL      = arg('--rpc',      'https://rpc.monad.xyz');
const CONTRACT     = arg('--contract', '');
const CSV_FILE     = arg('--csv',      '');
const SNAPSHOT_BLK = arg('--block',    '0');
const PRIVATE_KEY  = arg('--key',      '');

if (!CONTRACT || !CSV_FILE || !PRIVATE_KEY) {
  console.error('Usage: node load-snapshot.js --rpc <url> --contract <addr> --csv <file> --block <N> --key <privkey>');
  process.exit(1);
}

// ─── ABI (loadTickets only) ───────────────────────────────────────────────────
// loadTickets(address[],uint256[],uint256) selector
const LOAD_SELECTOR = '0x' + keccak256Hex('loadTickets(address[],uint256[],uint256)').slice(0, 8);

// ─── Minimal crypto (ABI encoding + keccak) ──────────────────────────────────
const crypto = require('crypto');

function keccak256Hex(str) {
  return crypto.createHash('sha3-256').update(str).digest('hex');
}

// Note: For production use, use ethers.js or viem for ABI encoding.
// This script outputs the encoded calldata for you to verify before sending.

function toHex(n) { return '0x' + BigInt(n).toString(16); }
function fromHex(s) { return parseInt(s, 16); }

let _reqId = 1;
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: _reqId++, method, params });
    const u    = new URL(RPC_URL);
    const mod  = u.protocol === 'https:' ? https : http;
    const req  = mod.request({
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
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

function parseCSV(file) {
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n');
  const header = lines[0].split(',');
  const wallets = [];
  const tickets = [];
  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split(',');
    const wallet  = cols[0].trim().toLowerCase();
    const t       = parseInt(cols[4] || cols[cols.length - 1], 10); // tickets column
    if (!wallet || isNaN(t) || t <= 0) continue;
    wallets.push(wallet);
    tickets.push(t);
  }
  return { wallets, tickets };
}

async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards — load snapshot to contract  ║');
  console.log('╚══════════════════════════════════════════╝\n');

  const { wallets, tickets } = parseCSV(CSV_FILE);
  const totalTickets = tickets.reduce((a, b) => a + b, 0);

  console.log(`CSV loaded: ${wallets.length} wallets, ${totalTickets} total tickets`);
  console.log(`Contract:   ${CONTRACT}`);
  console.log(`RPC:        ${RPC_URL}`);
  console.log(`Snapshot block: ${SNAPSHOT_BLK}\n`);

  // Validate
  if (wallets.length === 0) {
    console.error('[error] No valid entries in CSV');
    process.exit(1);
  }

  // For large snapshots, Foundry cast is the recommended approach.
  // This script outputs the data for you to use with cast or ethers.js.
  console.log('─────────────────────────────────────────────────────');
  console.log('Recommended: use Foundry cast to call loadTickets()');
  console.log('─────────────────────────────────────────────────────\n');

  // Write a foundry cast command file
  const walletsArg  = '[' + wallets.join(',') + ']';
  const ticketsArg  = '[' + tickets.join(',') + ']';

  const castCmd = `cast send ${CONTRACT} \\
  "loadTickets(address[],uint256[],uint256)" \\
  "${walletsArg}" \\
  "${ticketsArg}" \\
  ${SNAPSHOT_BLK} \\
  --rpc-url ${RPC_URL} \\
  --private-key $PRIVATE_KEY`;

  fs.writeFileSync('load_snapshot_cmd.sh', `#!/bin/bash\n${castCmd}\n`, 'utf8');
  console.log('Cast command written to: load_snapshot_cmd.sh');
  console.log('Review it, then run: bash load_snapshot_cmd.sh\n');

  // Also write wallets + tickets as JSON for manual verification
  const json = { snapshotBlock: parseInt(SNAPSHOT_BLK), wallets, tickets, totalTickets };
  fs.writeFileSync('snapshot_payload.json', JSON.stringify(json, null, 2), 'utf8');
  console.log('Payload written to: snapshot_payload.json');
  console.log('\nTop 5 entries:');
  for (let i = 0; i < Math.min(5, wallets.length); i++) {
    console.log(`  ${wallets[i]}  →  ${tickets[i]} tickets`);
  }
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
