#!/usr/bin/env node
/**
 * nft_snapshot.js
 * Takes a snapshot of current r3tards NFT holders.
 * For each tokenId (1..supply), calls ownerOf() and records the holder.
 * Output: wallet, count, token_ids
 *
 * Usage:
 *   node nft_snapshot.js --rpc https://rpc.monad.xyz --supply 1033 --out nft_snapshot.csv
 *   node nft_snapshot.js --rpc https://rpc.monad.xyz --supply 1033 --block 69612284 --out nft_snapshot.csv
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

const RPC_URL      = arg('--rpc',    'https://rpc.monad.xyz');
const TOTAL_SUPPLY = parseInt(arg('--supply', '1033'), 10);
const BLOCK_RAW    = arg('--block',  'latest');
const OUT_FILE     = arg('--out',    'nft_snapshot.csv');

const BLOCK_HEX = BLOCK_RAW === 'latest' ? 'latest' : '0x' + parseInt(BLOCK_RAW).toString(16);

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

function encodeOwnerOf(tokenId) {
  return '0x6352211e' + tokenId.toString(16).padStart(64, '0');
}

async function getOwner(tokenId, retries = 5) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const result = await rpc('eth_call', [{ to: NFT_ADDR, data: encodeOwnerOf(tokenId) }, BLOCK_HEX]);
      if (!result || result === '0x') return null;
      const owner = '0x' + result.slice(26).toLowerCase();
      if (owner === '0x' + '0'.repeat(40)) return null;
      if (owner === '0x000000000000000000000000000000000000dead') return null;
      return owner;
    } catch(e) {
      if (attempt === retries) {
        console.error(`\n[error] ownerOf(${tokenId}) failed: ${e.message}`);
        process.exit(1);
      }
      await sleep(500 * attempt);
    }
  }
}

async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards NFT snapshot                 ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`RPC:          ${RPC_URL}`);
  console.log(`Block:        ${BLOCK_RAW}`);
  console.log(`Total supply: ${TOTAL_SUPPLY}`);
  console.log(`Output:       ${OUT_FILE}\n`);

  console.log(`Fetching ownerOf for tokenIds 1–${TOTAL_SUPPLY} sequentially...\n`);
  const holders = new Map();

  for (let tokenId = 1; tokenId <= TOTAL_SUPPLY; tokenId++) {
    const owner = await getOwner(tokenId);
    if (owner) {
      if (!holders.has(owner)) holders.set(owner, []);
      holders.get(owner).push(tokenId);
    }
    if (tokenId % 50 === 0 || tokenId === TOTAL_SUPPLY) {
      process.stdout.write(`\r  ${tokenId}/${TOTAL_SUPPLY} checked (${holders.size} unique holders)...`);
    }
  }

  console.log(`\n\n${holders.size} unique holders found\n`);

  const lines = ['wallet,count,token_ids'];
  for (const [wallet, tokenIds] of [...holders.entries()].sort()) {
    lines.push(`${wallet},${tokenIds.length},"${tokenIds.join(',')}"`);
  }
  fs.writeFileSync(OUT_FILE, lines.join('\n'), 'utf8');

  console.log('══════════════════════════════════════════');
  console.log(`Unique holders : ${holders.size}`);
  console.log(`Total tokens   : ${[...holders.values()].reduce((s,t) => s+t.length, 0)}`);
  console.log(`Block          : ${BLOCK_RAW}`);
  console.log(`Output saved   : ${OUT_FILE}`);
  console.log('══════════════════════════════════════════\n');
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
