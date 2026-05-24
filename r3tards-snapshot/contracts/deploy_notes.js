// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Deployment script for R3tardsRaffle
 *
 * Using Foundry (recommended):
 *   forge create contracts/R3tardsRaffle.sol:R3tardsRaffle \
 *     --constructor-args 0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67 \
 *     --rpc-url https://rpc.monad.xyz \
 *     --private-key $PRIVATE_KEY \
 *     --verify
 *
 * Using Hardhat:
 *   npx hardhat run scripts/deploy.js --network monad
 *
 * ─── Hardhat deploy script ────────────────────────────────────────────────────
 * Save as scripts/deploy.js and run with Hardhat:
 */

/*
const { ethers } = require("hardhat");

async function main() {
  const SWITCHBOARD_MONAD_MAINNET = "0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67";

  console.log("Deploying R3tardsRaffle...");
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const Raffle = await ethers.getContractFactory("R3tardsRaffle");
  const raffle = await Raffle.deploy(SWITCHBOARD_MONAD_MAINNET);
  await raffle.waitForDeployment();

  console.log("R3tardsRaffle deployed to:", await raffle.getAddress());
  console.log("Switchboard:", SWITCHBOARD_MONAD_MAINNET);
  console.log("\nNext steps:");
  console.log("1. Load snapshot: raffle.loadTickets(wallets, tickets, snapshotBlock)");
  console.log("2. Deposit prize NFT: nft.safeTransferFrom(you, raffleAddress, tokenId)");
  console.log("3. Request draw: raffle.requestDraw({ value: fee })");
  console.log("4. Fulfill: raffle.fulfillDraw(randomnessObject)");
}

main().catch((e) => { console.error(e); process.exit(1); });
*/
