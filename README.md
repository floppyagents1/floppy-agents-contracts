# Floppy Agents & Floppy Market

Open-source contracts for **Floppy Agents** (3,333 fully on-chain pixel floppy NFTs) and **Floppy Market**, the agent-native, non-custodial marketplace on BNB Chain.

- Website: https://floppymarket.surge.sh/
- X: https://x.com/Floppyagents

## Deployed contracts (BNB Smart Chain, chain id 56)
| Contract | Address | Verification |
|---|---|---|
| Floppy Agents (ERC-721 + ERC-2981) | `0x8F1E4787f131990d793Af253d118aed7Fe1B29AF` | [BscScan – Exact Match](https://bscscan.com/address/0x8F1E4787f131990d793Af253d118aed7Fe1B29AF#code) · Sourcify exact match |
| Floppy Market | `0xf7480360Dcb56543349E7D43c093870d4ede5d5b` | [BscScan – Exact Match](https://bscscan.com/address/0xf7480360Dcb56543349E7D43c093870d4ede5d5b#code) · Sourcify match |

Compiler: solc 0.8.24, optimizer 200 runs, EVM cancun, OpenZeppelin v5.1.0.

## How the market works
- **Listings are non-custodial:** your NFT stays in your wallet until a buyer pays. Stale listings (token moved) cannot be bought.
- **Offers and collection bids** hold BNB in escrow; bidders can always withdraw.
- **Every sale:** 5% market fee (hard-capped at 5% in code), ERC-2981 royalty (5% today, capped at 10%), rest to the seller. Failed payouts are credited and claimable with `withdraw()`.
- **Owner powers (Ownable2Step):** set fee (≤5%), set fee recipient, pause/unpause. The owner has **no** function that moves NFTs, escrowed BNB or pending withdrawals. Withdrawals and cancelling listings work even while paused.

## Project wallets (public)
- Collection owner: `0xeD0F9aBC051c804EB4b7dC3dA17586c86bEF6740`
- Market owner, market fee and royalty receiver: `0x4D1fEdAc1E0B49923eF2a354ceCFdFAfcC4F8B99`

## Testing & analysis
- `FloppyMarket.t.sol`: 42 Foundry unit/fuzz tests (reentrancy, return-bomb, gas-burning receivers, fee math fuzz) + a BSC mainnet-fork sale test. Results: `test-results.txt` (43 passed, 0 failed).
- Slither static analysis: `slither-report.txt` (5 informational reentrancy-ordering notes; state is updated before transfers that matter and payouts use pull-payment fallback).

## Status
Not independently audited. Read the code and check prices before signing. Collectibles, not investments.

License: MIT
