import { ethers } from "hardhat";

async function main() {
  const BOTCOIN = "0xA601877977340862Ca67f816eb079958E5bd0BA3";
  const MINING = "0xd572e61e1B627d4105832C815Ccd722B5baD9233";
  const OPERATOR = "0x029257734e2346b43cf3beff69a95e5055b2d5e8"; // Bankr wallet
  const FEE_BPS = 500; // 5% operator fee

  const Pool = await ethers.getContractFactory("BotcoinPool");
  const pool = await Pool.deploy(BOTCOIN, MINING, OPERATOR, FEE_BPS);
  await pool.waitForDeployment();

  console.log("BotcoinPool deployed to:", await pool.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
