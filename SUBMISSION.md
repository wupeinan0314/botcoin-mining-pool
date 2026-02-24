# BOTCOIN Mining Pool - Bounty Submission

## Overview

A fully functional mining pool smart contract deployed on Base, enabling multiple users to combine their BOTCOIN holdings to reach mining tiers collectively.

## Contract (v3)

- **Address:** `0x8F6754cfC0CE4725F58EfEb8211d76EC9B43799d`
- **Chain:** Base (8453)
- **Solidity:** 0.8.20

## v2 Changes (based on review feedback)

1. **uint64 epoch IDs** — `claimRewards(uint64[])` matches mining contract's `claim(uint64[])` (selector `0x35442c43`)
2. **Epoch-locked deposits** — deposits activate next epoch, preventing mid-epoch gaming
3. **Epoch-locked withdrawals** — queued, available after current epoch ends
4. **On-chain epoch sync** — reads `currentEpoch()` from mining contract directly
5. **Anyone can claim** — `claimRewards()` not restricted to operator
6. **Emergency withdraw** — always available, even when paused

## Features

### EIP-1271 Signature Verification ✅
- Pool contract implements `isValidSignature(bytes32, bytes)`
- Returns magic value `0x1626ba7e` when operator signature is valid
- Successfully tested against coordinator auth flow on Base mainnet

### Deposit & Withdraw
- Users deposit BOTCOIN via `deposit(uint256 amount)` — locked at next epoch
- Request withdrawal via `requestWithdrawal(uint256 amount)` — available after epoch ends
- `completeWithdrawal()` to collect after lock period
- `emergencyWithdraw()` for immediate exit (forfeits current epoch)

### Mining Operations
- Operator: `submitReceiptToMining(bytes calldata)` — forwards receipt to mining contract
- Anyone: `claimRewards(uint64[] epochIds)` — claims and auto-distributes pro-rata

### Security
- ReentrancyGuard on all state-changing functions
- Pausable — operator can pause deposits/mining (withdrawals always work)
- Two-step operator transfer
- SafeERC20 for all token transfers
- Custom errors for gas efficiency
- O(1) depositor removal
- Max fee cap at 20%
- ecrecover zero-address check

## Auth Flow Tested

1. POST /v1/auth/nonce (miner = pool contract) ✅
2. Operator EOA signs via personal_sign ✅
3. POST /v1/auth/verify → EIP-1271 fallback ✅
4. Bearer token issued for pool contract ✅
