#!/usr/bin/env node
/**
 * load-snapshot.js
 * Reads the snapshot CSV and generates Foundry cast commands to call
 * initSnapshot() + loadTicketsBatch() + finalizeSnapshot() on the deployed contract.
 *
 * Usage:
 *   node load-snapshot.js \
 *     --contract <RAFFLE_CONTRACT_ADDRESS> \
 *     --csv snapshot_<block>.csv \
 *     --block <snapshotBlock> \
 *     --hash <gitCommitHashOrCSVHash> \
 *     --rpc https://rpc.monad.xyz \
 *     --batch-size 300
 *
 * Output:
 *   load_snapshot_cmd.sh  — shell script with all cast commands in order
 *   snapshot_payload.json — full payload for manual verification
 *
 * Note: --hash should be the git commit hash of the snapshot (0x-prefixed if hex,
 *       or pass as plain string and it will be right-padded to bytes32).
 *       Use `git rev-parse HEAD` after committing the CSV to get it.
 */

'use strict';

const fs = require('fs');

const args = process.argv.slice(2);
function arg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const CONTRACT    = arg('--contract',  '');
const CSV_FILE    = arg('--csv',       '');
const SNAPSHOT_BLK= arg('--block',     '0');
const SNAP_HASH   = arg('--hash',      '0x' + '0'.repeat(64));
const RPC_URL     = arg('--rpc',       'https://rpc.monad.xyz');
const BATCH_SIZE  = parseInt(arg('--batch-size', '300'), 10);

if (!CONTRACT || !CSV_FILE) {
  console.error([
    'Usage: node load-snapshot.js \\',
    '  --contract <addr> \\',
    '  --csv <file.csv> \\',
    '  --block <snapshotBlock> \\',
    '  --hash <gitCommitHash> \\',
    '  --rpc https://rpc.monad.xyz \\',
    '  --batch-size 300',
  ].join('\n'));
  process.exit(1);
}

// ─── Parse CSV ────────────────────────────────────────────────────────────────
function parseCSV(file) {
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n');
  // Expected header: wallet,r3tard_nft,r3tard_sbt,diamond_sbt,tickets
  const wallets = [];
  const tickets = [];
  for (let i = 1; i < lines.length; i++) {
    const cols   = lines[i].split(',');
    const wallet = cols[0].trim().toLowerCase();
    // tickets is always the last column
    const t      = parseInt(cols[cols.length - 1].trim(), 10);
    if (!wallet || !wallet.startsWith('0x') || isNaN(t) || t <= 0) continue;
    wallets.push(wallet);
    tickets.push(t);
  }
  return { wallets, tickets };
}

// ─── Chunk array ──────────────────────────────────────────────────────────────
function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

// ─── Format bytes32 from git hash string ──────────────────────────────────────
function toBytes32(str) {
  // Strip 0x if present, pad/truncate to 32 bytes
  const hex = str.startsWith('0x') ? str.slice(2) : Buffer.from(str).toString('hex');
  return '0x' + hex.slice(0, 64).padEnd(64, '0');
}

// ─── Main ─────────────────────────────────────────────────────────────────────
function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards — load snapshot to contract  ║');
  console.log('╚══════════════════════════════════════════╝\n');

  const { wallets, tickets } = parseCSV(CSV_FILE);
  if (wallets.length === 0) {
    console.error('[error] No valid entries in CSV');
    process.exit(1);
  }

  const totalTickets  = tickets.reduce((a, b) => a + b, 0);
  const snapshotHash  = toBytes32(SNAP_HASH);
  const walletBatches = chunk(wallets, BATCH_SIZE);
  const ticketBatches = chunk(tickets, BATCH_SIZE);

  console.log(`CSV:           ${CSV_FILE}`);
  console.log(`Wallets:       ${wallets.length}`);
  console.log(`Total tickets: ${totalTickets}`);
  console.log(`Snapshot block:${SNAPSHOT_BLK}`);
  console.log(`Snapshot hash: ${snapshotHash}`);
  console.log(`Contract:      ${CONTRACT}`);
  console.log(`RPC:           ${RPC_URL}`);
  console.log(`Batch size:    ${BATCH_SIZE} (${walletBatches.length} batch${walletBatches.length > 1 ? 'es' : ''})\n`);

  // ── Build cast commands ──────────────────────────────────────────────────────
  const cmds = [];

  cmds.push('#!/bin/bash');
  cmds.push('set -e  # stop on any error');
  cmds.push('');
  cmds.push(`# r3tards raffle snapshot loader`);
  cmds.push(`# Contract: ${CONTRACT}`);
  cmds.push(`# Snapshot block: ${SNAPSHOT_BLK}`);
  cmds.push(`# Snapshot hash: ${snapshotHash}`);
  cmds.push(`# Wallets: ${wallets.length} | Total tickets: ${totalTickets}`);
  cmds.push(`# Batches: ${walletBatches.length}`);
  cmds.push('');
  cmds.push('PRIVATE_KEY=${PRIVATE_KEY:?Set PRIVATE_KEY env var}');
  cmds.push(`RPC="${RPC_URL}"`);
  cmds.push(`CONTRACT="${CONTRACT}"`);
  cmds.push('');

  // Step 1: initSnapshot
  cmds.push('echo "Step 1/3: Initializing snapshot..."');
  cmds.push(`cast send $CONTRACT \\`);
  cmds.push(`  "initSnapshot(uint256,bytes32)" \\`);
  cmds.push(`  ${SNAPSHOT_BLK} \\`);
  cmds.push(`  "${snapshotHash}" \\`);
  cmds.push(`  --rpc-url $RPC \\`);
  cmds.push(`  --private-key $PRIVATE_KEY`);
  cmds.push('');

  // Step 2: loadTicketsBatch (one per batch)
  walletBatches.forEach((wBatch, i) => {
    const tBatch = ticketBatches[i];
    const wArg   = '"[' + wBatch.join(',') + ']"';
    const tArg   = '"[' + tBatch.join(',') + ']"';
    cmds.push(`echo "Step 2/${walletBatches.length}: Loading batch ${i + 1} of ${walletBatches.length} (${wBatch.length} wallets)..."`);
    cmds.push(`cast send $CONTRACT \\`);
    cmds.push(`  "loadTicketsBatch(address[],uint256[])" \\`);
    cmds.push(`  ${wArg} \\`);
    cmds.push(`  ${tArg} \\`);
    cmds.push(`  --rpc-url $RPC \\`);
    cmds.push(`  --private-key $PRIVATE_KEY`);
    cmds.push('');
  });

  // Step 3: finalizeSnapshot
  cmds.push('echo "Step 3/3: Finalizing snapshot..."');
  cmds.push(`cast send $CONTRACT \\`);
  cmds.push(`  "finalizeSnapshot()" \\`);
  cmds.push(`  --rpc-url $RPC \\`);
  cmds.push(`  --private-key $PRIVATE_KEY`);
  cmds.push('');
  cmds.push('echo "✓ Snapshot loaded and finalized."');
  cmds.push('echo "Next: deposit prize NFT, set deadline, then requestDraw()"');

  const script = cmds.join('\n');
  fs.writeFileSync('load_snapshot_cmd.sh', script, 'utf8');
  console.log('✓ Shell script written → load_snapshot_cmd.sh');
  console.log('  Review it, then run: PRIVATE_KEY=<key> bash load_snapshot_cmd.sh\n');

  // ── Write payload JSON for audit ─────────────────────────────────────────────
  const payload = {
    contract:      CONTRACT,
    rpc:           RPC_URL,
    snapshotBlock: parseInt(SNAPSHOT_BLK),
    snapshotHash,
    walletCount:   wallets.length,
    totalTickets,
    batches:       walletBatches.length,
    entries:       wallets.map((w, i) => ({ wallet: w, tickets: tickets[i] })),
  };
  fs.writeFileSync('snapshot_payload.json', JSON.stringify(payload, null, 2), 'utf8');
  console.log('✓ Payload written → snapshot_payload.json (for manual verification)\n');

  // ── Preview ───────────────────────────────────────────────────────────────────
  console.log('Top 5 entries:');
  for (let i = 0; i < Math.min(5, wallets.length); i++) {
    console.log(`  ${wallets[i]}  →  ${tickets[i]} tickets`);
  }
  console.log('');
}

main();
