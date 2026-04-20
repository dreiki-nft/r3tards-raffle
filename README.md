# r3tards snapshot

Auditable onchain snapshot for the r3tards NFT raffle.  
Pure Node.js — **zero dependencies**, raw JSON-RPC calls only.

## Contracts (Monad mainnet)

| Contract | Address |
|---|---|
| r3tards NFT | `0x200723A706de0013316E5cd8EBa2b3f53DD90c29` |
| r3tards Legacy SBT | `0xFC8fD04a3887Fc7936d121534F61f30c3d88c38D` |

## Ticket rules

| Holding | Tickets |
|---|---|
| 1 r3tard NFT | 1 |
| 1 r3tard SBT | 2 |
| 1 diamond SBT | 3 |

## Usage

```bash
# basic — snapshot at latest block
node snapshot.js

# custom RPC
node snapshot.js --rpc https://rpc.monad.xyz

# pin to a specific block (recommended for reproducibility)
node snapshot.js --to 1234567

# set diamond SBT tokenId threshold (tokens >= N are diamond tier)
node snapshot.js --dia-from 500

# full example
node snapshot.js \
  --rpc https://rpc.monad.xyz \
  --from 0 \
  --to 1234567 \
  --dia-from 500 \
  --out snapshot_final.csv

# change chunk size if RPC throws range errors (default 10000)
node snapshot.js --chunk 5000
```

## Output

CSV with columns: `wallet, r3tard_nft, r3tard_sbt, diamond_sbt, tickets`  
Sorted by tickets descending.

## Pinning the snapshot (audit trail)

After running, commit the output CSV so the git hash ties the snapshot
to a specific block and timestamp:

```bash
git add snapshot_<block>.csv
git commit -m "snapshot at block <block>"
git push origin main
```

The git commit hash is your audit proof. Anyone can:
1. Check out that commit
2. Re-run `node snapshot.js --to <block>` against the same RPC
3. Diff the CSV to verify it's identical

## Diamond SBT detection

The script separates diamond from r3tard SBTs by tokenId range.  
Use `--dia-from <N>` where N is the first tokenId minted in the diamond airdrop.  
If you ran two separate airdrop transactions, check the first tokenId emitted
in the diamond batch's Transfer events and pass that as `--dia-from`.

If all SBTs are in one contract with no tokenId distinction, set `--dia-from 0`
and treat all SBTs as one tier (adjust ticket rules accordingly).
