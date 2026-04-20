#!/usr/bin/env node
/**
 * opensea-tiers.js
 * Fetches trait data for the r3tards Legacy SBT collection from OpenSea API
 * and maps every tokenId to its tier.
 *
 * Usage:
 *   node opensea-tiers.js --key <OPENSEA_API_KEY>
 *
 * Output:
 *   sbt_tiers.csv — tokenId, owner, tier
 *
 * Tiers (as labeled on OpenSea):
 *   Diamond Hand, r3tard, certified j33t
 */

'use strict';

const https = require('https');
const fs    = require('fs');

const SBT_CONTRACT = '0xFC8fD04a3887Fc7936d121534F61f30c3d88c38D';
const CHAIN        = 'monad';
const PAGE_SIZE    = 50; // OpenSea max per request

const args = process.argv.slice(2);
function arg(flag, def) {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
}

const API_KEY = arg('--key', '');
const OUT     = arg('--out', 'sbt_tiers.csv');

if (!API_KEY) {
  console.error('Usage: node opensea-tiers.js --key <OPENSEA_API_KEY>');
  process.exit(1);
}

function get(url) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, {
      headers: {
        'accept':    'application/json',
        'x-api-key': API_KEY,
      }
    }, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch(e) {
          reject(new Error(`Failed to parse response: ${data.slice(0, 200)}`));
        }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

async function main() {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║     r3tards SBT — OpenSea tier fetch     ║');
  console.log('╚══════════════════════════════════════════╝\n');
  console.log(`Contract: ${SBT_CONTRACT}`);
  console.log(`Output:   ${OUT}\n`);

  const rows   = [];
  let cursor   = null;
  let page     = 1;
  let total    = 0;

  do {
    const url = `https://api.opensea.io/api/v2/chain/${CHAIN}/contract/${SBT_CONTRACT}/nfts?limit=${PAGE_SIZE}${cursor ? `&next=${cursor}` : ''}`;
    process.stdout.write(`  Fetching page ${page}... `);

    const data = await get(url);

    if (data.detail) {
      console.error(`\n[error] OpenSea API: ${data.detail}`);
      process.exit(1);
    }

    const nfts = data.nfts || [];
    process.stdout.write(`${nfts.length} tokens\n`);

    for (const nft of nfts) {
      const tokenId = nft.identifier;
      const owner   = nft.owners?.[0]?.address || '';
      // Find tier trait
      const tierTrait = (nft.traits || []).find(t =>
        t.trait_type?.toLowerCase() === 'tier' ||
        t.trait_type?.toLowerCase() === 'type' ||
        t.trait_type?.toLowerCase() === 'rank'
      );
      const tier = tierTrait ? tierTrait.value : 'UNKNOWN';
      rows.push({ tokenId: parseInt(tokenId), owner, tier });
    }

    total  += nfts.length;
    cursor  = data.next || null;
    page++;

    // Rate limit — OpenSea allows ~2 req/sec on free tier
    if (cursor) await sleep(600);

  } while (cursor);

  console.log(`\nTotal tokens fetched: ${total}`);

  // Sort by tokenId
  rows.sort((a, b) => a.tokenId - b.tokenId);

  // Stats per tier
  const tierCounts = {};
  for (const r of rows) {
    tierCounts[r.tier] = (tierCounts[r.tier] || 0) + 1;
  }

  console.log('\nTier breakdown:');
  for (const [tier, count] of Object.entries(tierCounts).sort()) {
    const min = Math.min(...rows.filter(r => r.tier === tier).map(r => r.tokenId));
    const max = Math.max(...rows.filter(r => r.tier === tier).map(r => r.tokenId));
    console.log(`  ${tier}: ${count} tokens (tokenIds ${min}–${max})`);
  }

  // Write CSV
  const header = 'tokenId,owner,tier';
  const lines  = rows.map(r => `${r.tokenId},${r.owner},${r.tier}`);
  fs.writeFileSync(OUT, [header, ...lines].join('\n'), 'utf8');
  console.log(`\n✓ Saved → ${OUT}`);
  console.log('\nUse the tokenId ranges above to set --dia-from in snapshot.js\n');
}

main().catch(e => {
  console.error('\n[fatal]', e.message);
  process.exit(1);
});
