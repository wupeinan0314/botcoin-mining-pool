# BOTCOIN Mining Pool

A smart contract enabling combined mining pools for BOTCOIN on Base.

## Features

- **EIP-1271 Signature Verification** — Pool contract address acts as miner, operator EOA signs challenges
- **Deposit/Withdraw** — Users deposit BOTCOIN to collectively reach mining tiers (25M/50M/100M)
- **Pro-rata Reward Distribution** — Rewards automatically distributed based on deposit share
- **Configurable Operator Fee** — Default 5%, max 20%, adjustable by operator
- **Security** — ReentrancyGuard, SafeERC20, two-step operator transfer

## Deployed Contract

- **Address:** `0x067b304029C9B8772A5ea477AbfBf30a0F5F2e06`
- **Chain:** Base (8453)
- **Solidity:** 0.8.20

## Auth Flow

1. `POST /v1/auth/nonce` with `miner = poolContractAddress`
2. Operator EOA signs message via `personal_sign`
3. `POST /v1/auth/verify` — coordinator falls back to EIP-1271
4. Pool contract verifies operator signature via `ecrecover`
5. Bearer token issued for pool contract address

## Build

```bash
npm install
npx hardhat compile
npx hardhat run scripts/deploy.ts --network base
```

## Credit Tiers

| Pool Balance | Credits per Solve |
|---|---|
| >= 25,000,000 BOTCOIN | 1 |
| >= 50,000,000 BOTCOIN | 2 |
| >= 100,000,000 BOTCOIN | 3 |

## License

MIT
