#!/usr/bin/env node
/**
 * settle-randomness.js
 * Fetches randomness data from Switchboard, waits until ready,
 * then gets encoded payload from Crossbar for fulfillDraw.
 *
 * Usage:
 *   node settle-randomness.js <RANDOMNESS_ID> [--network testnet|mainnet]
 *
 * Example (testnet):
 *   node settle-randomness.js 0x85548c76cb1fa3588cf866e3fcc380fbd1193ad70a7272db4dcdd07427effcbd
 *
 * Example (mainnet):
 *   node settle-randomness.js 0xABC123... --network mainnet
 */

'use strict';

const https = require('https');

const RAND_ID  = process.argv[2];
const NETWORK  = process.argv.includes('--network') ? process.argv[process.argv.indexOf('--network') + 1] : 'testnet';
const CHAIN_ID = NETWORK === 'mainnet' ? '143' : '10143';
const SWITCHBOARD = NETWORK === 'mainnet'
  ? '0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67'
  : '0x6724818814927e057a693f4e3A172b6cC1eA690C'; // confirmed Monad testnet
const RPC_URL = NETWORK === 'mainnet'
  ? 'https://rpc.monad.xyz'
  : 'https://testnet-rpc.monad.xyz';
const BUFFER_SECS = 15;

if (!RAND_ID || !RAND_ID.startsWith('0x')) {
  console.error('Usage: node settle-randomness.js <RANDOMNESS_ID> [--network testnet|mainnet]');
  console.error('Example: node settle-randomness.js 0x85548c76...');
  process.exit(1);
}

function rpcCall(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
    const req  = https.request({
      hostname: RPC_URL.replace('https://', ''),
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

async function getRandomnessData(randId) {
  // getRandomness(bytes32) — confirmed selector 0x05b19402
  const selectors = ['05b19402'];
  for (const sel of selectors) {
    try {
      const data   = '0x' + sel + randId.replace('0x', '').padStart(64, '0');
      const result = await rpcCall('eth_call', [{ to: SWITCHBOARD, data }, 'latest']);
      if (result && result !== '0x' && result.length > 10) {
        const hex = result.replace('0x', '');
        return {
          rollTimestamp:      BigInt('0x' + hex.slice(3 * 64, 4 * 64)),
          minSettlementDelay: BigInt('0x' + hex.slice(4 * 64, 5 * 64)),
          oracle:             '0x' + hex.slice(5 * 64 + 24, 6 * 64),
          value:              BigInt('0x' + hex.slice(6 * 64, 7 * 64)),
          settledAt:          BigInt('0x' + hex.slice(7 * 64, 8 * 64)),
        };
      }
    } catch(e) { /* try next */ }
  }
  throw new Error('Could not read randomness data from Switchboard contract — unknown selector');
}

async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards — settle randomness          ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`randomnessId: ${RAND_ID}`);
  console.log(`network:      ${NETWORK} (chainId ${CHAIN_ID})`);
  console.log(`switchboard:  ${SWITCHBOARD}\n`);

  // Read randomness data from Switchboard
  console.log('Reading randomness data from Switchboard contract...');
  let randData;
  try {
    randData = await getRandomnessData(RAND_ID);
    console.log(`rollTimestamp:      ${randData.rollTimestamp}`);
    console.log(`minSettlementDelay: ${randData.minSettlementDelay}`);
    console.log(`oracle:             ${randData.oracle}`);
    console.log(`settledAt:          ${randData.settledAt}`);
    if (randData.settledAt > 0n) {
      console.log('\n✅ Already settled! value:', randData.value.toString());
    }
  } catch(e) {
    console.warn(`\n[warn] Could not read from Switchboard contract: ${e.message}`);
    console.warn('Proceeding with timestamp=0 and no oracle (may fail)\n');
    randData = { rollTimestamp: 0n, minSettlementDelay: 1n, oracle: null, settledAt: 0n };
  }

  // Wait until ready
  const readyAt  = Number(randData.rollTimestamp) + Number(randData.minSettlementDelay) + BUFFER_SECS;
  const nowSecs  = Math.floor(Date.now() / 1000);
  const waitSecs = Math.max(0, readyAt - nowSecs);

  if (waitSecs > 0) {
    console.log(`\nWaiting ${waitSecs}s until ready...`);
    for (let i = waitSecs; i > 0; i--) {
      process.stdout.write(`\r  ${i}s remaining...  `);
      await sleep(1000);
    }
    console.log('\r  Ready!              ');
  } else {
    console.log('\nRandomness should be ready now, fetching...');
  }

  // Fetch from Crossbar
  console.log('Fetching encoded randomness from Crossbar...');
  const payload = {
    randomness_id:         RAND_ID,
    network:               NETWORK,
    chain_id:              CHAIN_ID,
    timestamp:             Number(randData.rollTimestamp),
    min_staleness_seconds: Number(randData.minSettlementDelay),
  };
  if (randData.oracle && randData.oracle !== '0x' + '0'.repeat(40)) {
    payload.oracle = randData.oracle;
  }

  const crossbar = await postCrossbar(payload);

  if (!crossbar.success) {
    console.error('\n[error] Crossbar:', JSON.stringify(crossbar));
    process.exit(1);
  }

  const encoded = crossbar.data.encoded;
  console.log('\n✅ SUCCESS!\n');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Paste into fulfillDraw() in Remix RIGHT NOW:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(encoded);
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('\nmsg.value: 0 (fee is 0 on testnet)');
  console.log('⚠️  Paste and call fulfillDraw immediately — payload expires!\n');
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
