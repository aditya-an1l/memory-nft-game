const { ethers } = require("hardhat");

async function main() {
  console.log("Deploying MemoryGame contract...");

  const MemoryGame = await ethers.getContractFactory("MemoryGame");
  const memoryGame = await MemoryGame.deploy();

  await memoryGame.waitForDeployment();

  const address = await memoryGame.getAddress();
  console.log("✅ MemoryGame deployed to:", address);
  console.log("🔗 View on Etherscan: https://sepolia.etherscan.io/address/" + address);
  console.log("");
  console.log("📋 Copy this address into index.html:");
  console.log('   const CONTRACT_ADDRESS = "' + address + '";');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
