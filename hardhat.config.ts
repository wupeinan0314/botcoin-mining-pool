import type { HardhatUserConfig } from "hardhat/config";

const config: HardhatUserConfig = {
  solidity: "0.8.20",
  networks: {
    base: {
      type: "http",
      url: "https://base-mainnet.g.alchemy.com/v2/BnLcGG_Ko-6_AfPBjZR4E6IDqF9-mpzW",
      chainId: 8453,
      accounts: ["0x36187477750447bd8d6ee0d2282a47502a5ed1e44c23df1d2c8b4e1192e75e3f"],
    },
  },
};

export default config;
