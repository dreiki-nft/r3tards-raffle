#!/usr/bin/env node
/**
 * r3tards SBT inspector
 * Fetches all SBT Transfer events and dumps every tokenId + current owner
 * Use this to find the diamond tier tokenId boundary (--dia-from)
 *
 * Usage:
 *   node inspect-sbts.js [--rpc <url>] [--from <block>] [--to <block>] [--chunk <size>]
 *
 * Output:
 *   - Console: sorted tokenId list with owners
 *   - File: sbt_tokens.csv (tokenId, owner, status)
 */

'use strict';

const https = require('https');
const http  = require('http');
const fs    = require('fs');

const SBT_ADDR  = '0xFC8fD04a3887Fc7936d121534F61f30c3d88c38D';
const TRANSFER  = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

const args = process.argv.slice(2);
function arg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const RPC_URL  = arg('--rpc',   'https://rpc.monad.xyz');
const FROM_RAW = arg('--from',  '0');
const TO_RAW   = arg('--to',    'latest');
const CHUNK    = parseInt(arg('--chunk', '10000'), 10);

const toHex   = n => '0x' + BigInt(n).toString(16);
const fromHex = s => parseInt(s, 16);

let _reqId = 1;
function rpc(url, method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: _reqId++, method, params });
    const u = new URL(url);
    const mod = u.protocol === 'https:' ? https : http;
    const req = mod.request({
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
  let from = fromBlock;
  while (from <= toBlock) {
    const to = Math.min(from + CHUNK - 1, toBlock);
    process.stdout.write(`  blocks ${from}–${to} `);
    try {
      const logs = await rpc(RPC_URL, 'eth_getLogs', [{
        address,
        topics: [TRANSFER],
        fromBlock: toHex(from),
        toBlock: toHex(to),
      }]);
      process.stdout.write(`→ ${logs.length} events\n`);
      all.push(...logs);
    } catch(e) {
      process.stdout.write(`\n`);
      if (e.message.includes('range') || e.message.includes('limit') || e.message.includes('too many')) {
        console.warn(`  [warn] range too large, halving chunk...`);
        const mid = Math.floor((from + to) / 2);
        all.push(...await getLogsChunked(address, from, mid));
        all.push(...await getLogsChunked(address, mid + 1, to));
        from = to + 1;
        continue;
      }
      throw e;
    }
    from = to + 1;
  }
  return all;
}

async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║       r3tards SBT inspector              ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`RPC: ${RPC_URL}`);
  console.log(`SBT: ${SBT_ADDR}\n`);

  const latestBlock = await getBlockNumber();
  const fromBlock   = FROM_RAW === '0' ? 0 : parseInt(FROM_RAW, 10);
  const toBlock     = TO_RAW === 'latest' ? latestBlock : parseInt(TO_RAW, 10);

  console.log(`Block range: ${fromBlock} → ${toBlock}\n`);
  console.log('Fetching SBT Transfer events...');

  const logs = await getLogsChunked(SBT_ADDR, fromBlock, toBlock);
  console.log(`\nTotal Transfer events: ${logs.length}\n`);

  // Build tokenId → { owner, mintedTo, mintBlock, txHash }
  const tokens = new Map();

  for (const evt of logs) {
    const from    = ('0x' + evt.topics[1].slice(26)).toLowerCase();
    const to      = ('0x' + evt.topics[2].slice(26)).toLowerCase();
    const tokenId = evt.topics[3] ? fromHex(evt.topics[3]) : null;
    if (tokenId === null) {
      console.warn(`  [warn] event missing tokenId in topics[3] — tx ${evt.transactionHash}`);
      continue;
    }

    const isMint = from === ZERO_ADDR;
    const isBurn = to   === ZERO_ADDR;

    if (!tokens.has(tokenId)) {
      tokens.set(tokenId, {
        tokenId,
        mintedTo:  isMint ? to : '?',
        mintBlock: isMint ? fromHex(evt.blockNumber) : '?',
        mintTx:    isMint ? evt.transactionHash : '?',
        owner:     isBurn ? null : to,
        burned:    isBurn,
        transfers: 0,
      });
    } else {
      const t = tokens.get(tokenId);
      t.owner   = isBurn ? null : to;
      t.burned  = isBurn;
      if (!isMint) t.transfers++;
    }
  }

  // Sort by tokenId
  const sorted = [...tokens.values()].sort((a, b) => a.tokenId - b.tokenId);

  const active  = sorted.filter(t => !t.burned && t.owner);
  const burned  = sorted.filter(t => t.burned);

  console.log('──────────────────────────────────────────');
  console.log(`Total tokens minted : ${sorted.length}`);
  console.log(`Active (not burned) : ${active.length}`);
  console.log(`Burned              : ${burned.length}`);
  console.log('──────────────────────────────────────────\n');

  // Group by mint tx to show airdrop batches
  const batches = new Map();
  for (const t of sorted) {
    if (t.mintTx === '?') continue;
    if (!batches.has(t.mintTx)) batches.set(t.mintTx, []);
    batches.get(t.mintTx).push(t.tokenId);
  }

  console.log(`Mint transactions (airdrop batches): ${batches.size}`);
  console.log('─────────────────────────────────────────────────────────');
  let batchNum = 1;
  for (const [tx, ids] of batches) {
    const minId = Math.min(...ids);
    const maxId = Math.max(...ids);
    console.log(`  Batch ${batchNum++}: tx ${tx.slice(0,18)}...  tokenIds ${minId}–${maxId}  (${ids.length} tokens)`);
  }
  console.log('─────────────────────────────────────────────────────────\n');

  // Full token list
  console.log('All tokens (tokenId | owner | mintBlock | mintTx):');
  console.log('──────────────────────────────────────────────────────────────────────────');
  for (const t of sorted) {
    const owner  = t.burned ? '[BURNED]' : t.owner;
    const short  = owner && owner !== '[BURNED]'
      ? owner.slice(0, 8) + '...' + owner.slice(-6)
      : owner;
    const block  = t.mintBlock !== '?' ? String(t.mintBlock).padStart(8) : '       ?';
    const tx     = t.mintTx !== '?' ? t.mintTx.slice(0, 14) + '...' : '?';
    console.log(`  tokenId ${String(t.tokenId).padStart(5)}  |  ${short}  |  block ${block}  |  ${tx}`);
  }

  // CSV output
  const outFile = 'sbt_tokens.csv';
  const header  = 'tokenId,owner,burned,minted_to,mint_block,mint_tx,transfers';
  const lines   = sorted.map(t =>
    `${t.tokenId},${t.burned ? '' : t.owner},${t.burned},${t.mintedTo},${t.mintBlock},${t.mintTx},${t.transfers}`
  );
  fs.writeFileSync(outFile, [header, ...lines].join('\n'), 'utf8');

  console.log(`\n✓ Full token list saved → ${outFile}`);
  console.log(`\nUse the batch breakdown above to identify the diamond tier tokenId boundary.`);
  console.log(`Then run: node snapshot.js --dia-from <first diamond tokenId>\n`);
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
