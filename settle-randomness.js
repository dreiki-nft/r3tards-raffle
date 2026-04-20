#!/usr/bin/env node
/**
 * settle-randomness.js
 * Reads resolver params from the raffle contract, waits until ready,
 * fetches encoded payload from Crossbar, and prints it for fulfillDraw.
 *
 * Usage:
 *   node settle-randomness.js <RAFFLE_CONTRACT_ADDRESS> [--network testnet|mainnet]
 *
 * Example (testnet):
 *   node settle-randomness.js 0xYourRaffleContract
 *
 * Example (mainnet):
 *   node settle-randomness.js 0xYourRaffleContract --network mainnet
 */

'use strict';

const https = require('https');

const CONTRACT = process.argv[2];
const NETWORK  = process.argv.includes('--network')
  ? process.argv[process.argv.indexOf('--network') + 1]
  : 'testnet';

const CHAIN_ID    = NETWORK === 'mainnet' ? '143' : '10143';
const RPC_URL     = NETWORK === 'mainnet' ? 'rpc.monad.xyz' : 'testnet-rpc.monad.xyz';
const BUFFER_SECS = 15;

if (!CONTRACT || !CONTRACT.startsWith('0x')) {
  console.error('Usage: node settle-randomness.js <RAFFLE_CONTRACT_ADDRESS> [--network testnet|mainnet]');
  process.exit(1);
}

// ─── RPC ──────────────────────────────────────────────────────────────────────
function rpcCall(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
    const req  = https.request({
      hostname: RPC_URL,
      path:     '/',
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

// ─── Crossbar ─────────────────────────────────────────────────────────────────
function postCrossbar(body) {
  return new Promise((resolve, reject) => {
    const bodyStr = JSON.stringify(body);
    const req = https.request({
      hostname: 'crossbar.switchboard.xyz',
      path:     '/randomness/evm',
      method:   'POST',
      headers:  { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(bodyStr) },
    }, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch(e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(bodyStr);
    req.end();
  });
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ─── getResolverParams() ──────────────────────────────────────────────────────
// selector: keccak256('getResolverParams()') — we'll try the known one
async function getResolverParams() {
  // getResolverParams() returns:
  // uint256 chainId, bytes32 randomnessId, address oracle,
  // uint256 rollTimestamp, uint64 minSettlementDelay, uint256 fee
  const result = await rpcCall('eth_call', [{
    to:   CONTRACT,
    data: '0x6b5e4a7a' // keccak256('getResolverParams()')
  }, 'latest']);

  if (!result || result === '0x' || result.length < 10) {
    throw new Error('getResolverParams() returned empty — wrong selector or contract not in DrawRequested state');
  }

  const hex = result.replace('0x', '');
  const slot = i => '0x' + hex.slice(i * 64, i * 64 + 64);

  return {
    chainId:            BigInt(slot(0)),
    randomnessId:       slot(1),
    oracle:             '0x' + hex.slice(2 * 64 + 24, 3 * 64),
    rollTimestamp:      BigInt(slot(3)),
    minSettlementDelay: BigInt(slot(4)),
    fee:                BigInt(slot(5)),
  };
}

// ─── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards — settle randomness          ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`Contract: ${CONTRACT}`);
  console.log(`Network:  ${NETWORK} (chainId ${CHAIN_ID})\n`);

  // Step 1: Read all resolver params from contract
  console.log('Reading resolver params from contract...');
  const params = await getResolverParams();
  console.log(`randomnessId:       ${params.randomnessId}`);
  console.log(`oracle:             ${params.oracle}`);
  console.log(`rollTimestamp:      ${params.rollTimestamp}`);
  console.log(`minSettlementDelay: ${params.minSettlementDelay}`);
  console.log(`fee:                ${params.fee}`);

  if (params.randomnessId === '0x' + '0'.repeat(64)) {
    console.error('\n[error] randomnessId is zero — call requestDraw() first');
    process.exit(1);
  }

  // Step 2: Wait until rollTimestamp + minSettlementDelay + buffer
  const readyAt  = Number(params.rollTimestamp) + Number(params.minSettlementDelay) + BUFFER_SECS;
  const nowSecs  = Math.floor(Date.now() / 1000);
  const waitSecs = Math.max(0, readyAt - nowSecs);

  if (waitSecs > 0) {
    console.log(`\nWaiting ${waitSecs}s (rollTimestamp + delay + ${BUFFER_SECS}s buffer)...`);
    for (let i = waitSecs; i > 0; i--) {
      process.stdout.write(`\r  ${i}s remaining...  `);
      await sleep(1000);
    }
    console.log('\r  Ready!              ');
  } else {
    console.log('\nReady now, fetching from Crossbar...');
  }

  // Step 3: Fetch encoded payload from Crossbar
  const payload = {
    randomness_id:         params.randomnessId,
    network:               NETWORK,
    chain_id:              CHAIN_ID,
    timestamp:             Number(params.rollTimestamp),
    min_staleness_seconds: Number(params.minSettlementDelay),
    oracle:                params.oracle,
  };

  console.log('Fetching from Crossbar with payload:');
  console.log(JSON.stringify(payload, null, 2));

  const crossbar = await postCrossbar(payload);

  if (!crossbar.success) {
    console.error('\n[error] Crossbar returned:', JSON.stringify(crossbar, null, 2));
    process.exit(1);
  }

  const encoded = crossbar.data.encoded;

  console.log('\n✅ SUCCESS!\n');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Paste into fulfillDraw() in Remix RIGHT NOW:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(encoded);
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(`\nmsg.value: ${params.fee} wei (${Number(params.fee)} MON)`);
  console.log('⚠️  Call fulfillDraw immediately — payload expires!\n');
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
