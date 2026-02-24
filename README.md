# BOTCOIN Mining Pool

A smart contract enabling combined mining pools for BOTCOIN on Base. Users deposit BOTCOIN to collectively reach mining tiers, while an operator handles the inference work and submits solutions on behalf of the pool.

## Bounty Submission

This contract was built in response to the [100M BOTCOIN bounty](https://x.com/MineBotcoin) for a combined mining pool implementation.

- **Deployed Contract (v3):** [`0x8F6754cfC0CE4725F58EfEb8211d76EC9B43799d`](https://basescan.org/address/0x8F6754cfC0CE4725F58EfEb8211d76EC9B43799d)
- **Chain:** Base (8453)
- **Solidity:** 0.8.20
- **Dependencies:** OpenZeppelin Contracts (ReentrancyGuard, Pausable, SafeERC20)

## How It Works

### v2 Improvements (based on review feedback)

- **uint64 epoch IDs** — `claimRewards(uint64[])` matches the mining contract's `claim(uint64[])` signature (selector `0x35442c43`)
- **Epoch-locked deposits** — deposits activate at the start of the next epoch, preventing mid-epoch entry/exit gaming
- **Epoch-locked withdrawals** — withdrawal requests are queued and available after the current epoch ends
- **On-chain epoch sync** — reads `currentEpoch()` directly from the mining contract, no manual tracking needed
- **Anyone can claim rewards** — `claimRewards()` is not restricted to operator; any depositor can trigger reward distribution
- **Emergency withdraw** — users can always exit, even when paused, forfeiting current epoch rewards
- **processEpoch()** — public function to process epoch transitions, activating pending deposits

### For Depositors

1. **Approve** BOTCOIN spending to the pool contract
2. **Deposit** BOTCOIN via `deposit(amount)` — your share determines your reward proportion
3. **Earn** rewards automatically when the operator claims epoch rewards
4. **Claim** accumulated rewards via `claimUserRewards()`
5. **Withdraw** your deposit anytime via `withdraw(amount)` or `withdrawAll()`

### For the Operator

1. **Authenticate** with the coordinator using the pool contract as the miner address
2. **Solve** challenges using your LLM inference infrastructure
3. **Submit** receipts via `submitReceiptToMining(calldata)`
4. **Claim** epoch rewards via `claimRewards(epochIds)` — auto-distributes to depositors
5. **Earn** a configurable fee (default 5%, max 20%) on all rewards

### Credit Tiers

Pool balance determines credits earned per solve:

| Pool Balance | Credits per Solve |
|---|---|
| ≥ 25,000,000 BOTCOIN | 1 |
| ≥ 50,000,000 BOTCOIN | 2 |
| ≥ 100,000,000 BOTCOIN | 3 |

## EIP-1271 Auth Flow

The coordinator authenticates miners via signed nonces. For smart contract miners, it falls back to EIP-1271:

```
1. POST /v1/auth/nonce  →  miner = pool contract address
2. Operator EOA signs the nonce message (personal_sign)
3. POST /v1/auth/verify  →  coordinator calls pool.isValidSignature(hash, sig)
4. Pool contract ecrecovers → checks against stored operator → returns 0x1626ba7e
5. Coordinator issues Bearer token for pool contract address
```

**Tested and verified** against the live coordinator on Base mainnet. ✅

## Security Features

- **ReentrancyGuard** on all state-changing functions
- **Pausable** — operator can pause deposits/mining in emergencies (withdrawals always work)
- **Two-step operator transfer** — prevents accidental ownership loss
- **SafeERC20** for all token transfers
- **Custom errors** for gas-efficient reverts
- **O(1) depositor removal** via swap-and-pop pattern
- **Max fee cap** at 20% — operator cannot set excessive fees
- **No operator access to deposits** — operator can only claim mining rewards, never user funds
- **ecrecover zero-address check** — prevents signature malleability attacks

## Contract Interface

### Depositor Functions
| Function | Description |
|---|---|
| `deposit(uint256 amount)` | Deposit BOTCOIN into the pool |
| `withdraw(uint256 amount)` | Withdraw BOTCOIN from the pool |
| `withdrawAll()` | Withdraw deposit + unclaimed rewards |
| `claimUserRewards()` | Claim accumulated mining rewards |

### Operator Functions
| Function | Description |
|---|---|
| `submitReceiptToMining(bytes data)` | Forward receipt calldata to mining contract |
| `claimRewards(uint256[] epochIds)` | Claim epoch rewards and auto-distribute |
| `advanceEpoch(uint256 newEpochId)` | Update current epoch tracker |
| `setOperatorFee(uint256 newFeeBps)` | Adjust operator fee (max 20%) |
| `transferOperator(address)` | Initiate operator transfer |
| `pause()` / `unpause()` | Emergency pause/unpause |

### View Functions
| Function | Description |
|---|---|
| `getTierLevel()` | Current mining tier (0/1/2/3) |
| `getPoolBalance()` | Total BOTCOIN in pool |
| `getDepositorCount()` | Number of active depositors |
| `getDepositorInfo(address)` | User's deposit, epoch, rewards, status |
| `getPoolStats()` | Full pool statistics |

## Build & Deploy

```bash
# Install dependencies
npm install

# Compile
npx hardhat compile

# Deploy (configure hardhat.config.ts with your network)
npx hardhat run scripts/deploy.ts --network base
```

### Constructor Parameters

| Parameter | Description |
|---|---|
| `_botcoin` | BOTCOIN token address (`0xA601877977340862Ca67f816eb079958E5bd0BA3`) |
| `_miningContract` | Mining contract address (`0xd572e61e1B627d4105832C815Ccd722B5baD9233`) |
| `_operator` | Operator EOA address (signs challenges) |
| `_feeBps` | Operator fee in basis points (500 = 5%) |

## Architecture

```
┌─────────────┐     deposit/withdraw      ┌──────────────┐
│  Depositors │ ◄──────────────────────── │  BotcoinPool │
│  (Users)    │  claimUserRewards()       │  (Contract)  │
└─────────────┘                           └──────┬───────┘
                                                 │
                    submitReceiptToMining()       │  isValidSignature()
                    claimRewards()               │
                                                 │
┌─────────────┐     signs challenges      ┌──────┴───────┐
│  Operator   │ ─────────────────────────►│ Coordinator  │
│  (EOA)      │     submits solutions     │  (Backend)   │
└─────────────┘                           └──────────────┘
                                                 │
                                                 ▼
                                          ┌──────────────┐
                                          │   Mining     │
                                          │  Contract    │
                                          └──────────────┘
```

## License

MIT
