# BOTCOIN Mining Pool - Bounty Submission

## Overview

A fully functional mining pool smart contract deployed on Base, enabling multiple users to combine their BOTCOIN holdings to reach mining tiers collectively.

## Contract

- **Address:** `0x067b304029C9B8772A5ea477AbfBf30a0F5F2e06`
- **Chain:** Base (8453)
- **Solidity:** 0.8.20

## Features

### EIP-1271 Signature Verification ✅
- Pool contract implements `isValidSignature(bytes32, bytes)` 
- Returns magic value `0x1626ba7e` when operator signature is valid
- Successfully tested against coordinator auth flow (nonce → sign → verify → token)

### Deposit & Withdraw
- Users deposit BOTCOIN via `deposit(uint256 amount)`
- Withdrawals via `withdraw(uint256 amount)`
- Tracks depositors and balances for pro-rata distribution

### Mining Operations (Operator Only)
- `submitReceiptToMining(bytes calldata)` — forwards receipt to mining contract
- `claimRewards(uint256[] epochIds)` — claims epoch rewards and auto-distributes

### Reward Distribution
- Automatic pro-rata distribution to depositors on claim
- Configurable operator fee (default 5%, max 20%)
- Users claim accumulated rewards via `claimUserRewards()`

### Security
- ReentrancyGuard on all state-changing functions
- Two-step operator transfer (transferOperator → acceptOperator)
- Operator never touches user deposits
- SafeERC20 for all token transfers

### View Functions
- `getTierLevel()` — returns current tier (0/1/2/3)
- `getPoolBalance()` — total BOTCOIN in pool
- `getDepositorCount()` — number of depositors

## Auth Flow Tested

1. POST /v1/auth/nonce with miner = pool contract address ✅
2. Operator EOA signs message via personal_sign ✅
3. POST /v1/auth/verify — coordinator falls back to EIP-1271 ✅
4. Pool contract verifies operator signature via ecrecover ✅
5. Bearer token issued for pool contract address ✅

## Source Code

Full Solidity source available upon request or can be verified on BaseScan.
