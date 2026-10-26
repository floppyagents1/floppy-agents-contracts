# Floppy Agents Whitepaper

*Version 1.0, October 2026*

> Floppy Agents is a collectible art project. It is not an investment, carries no token, and makes no promise of profit, airdrops, or future value.

## 1. Summary

Floppy Agents is a collection of **3,333 pixel floppy disk NFTs** on **BNB Smart Chain**, built for the AI agent era. Every image and every trait lives fully on-chain as SVG, so the art can't disappear with a server.

Minting was **free** and limited to wallets holding a **.ai Agent ID**, one per wallet. The collection trades on **Floppy Market**, a non-custodial marketplace where every action is a prompt your AI agent wallet can sign.

## 2. Why floppies

The floppy disk was where software used to live. AI agents are the new software, and they now hold their own wallets. Floppy Agents gives those agents a collectible of their own: small, retro, and permanent.

## 3. The collection

| | |
|---|---|
| Supply | 3,333 (hard cap in the contract) |
| Chain | BNB Smart Chain (chain ID 56) |
| Standard | ERC-721 with ERC-2981 royalties |
| Mint price | Free (the contract rejects any payment) |
| Eligibility | Wallet must hold a .ai Agent ID |
| Limit | 1 public mint per wallet |
| Creator reserve | Up to 33 tokens, enforced on-chain |
| Art | 100% on-chain SVG and JSON metadata |

### Rarity

Each token gets a random seed at mint. The seed sets its tier and traits.

| Tier | Odds |
|---|---|
| Common | 50% |
| Uncommon | 25% |
| Rare | 15% |
| Epic | 8% |
| Legendary | 2% |

### Traits

- **Disk**: body color, three shades per tier.
- **Label**: label art; higher tiers unlock more designs, and Legendaries carry Agent Eyes or the BNB mark.
- **Shutter**: Silver or Black, Gold for Epic, Holo for Legendary.
- **Background**: six backdrops.
- **Capacity**: 720KB or 1.44MB, and 2.88MB for Rare and above.

Anyone can read a token's rarity directly from the contract with `rarityOf(tokenId)`.

## 4. Floppy Market

Floppy Market is the collection's own marketplace at floppymarket.surge.sh.

**Agent-native.** There is no browser wallet popup. Every action, from listing to buying, making offers, collection bids and withdrawals, comes as a ready-made prompt to paste into an AI agent wallet such as the Binance Agentic Wallet. The agent simulates the transaction and signs it. "Connecting" a wallet on the site only means pasting an address so the page can show what you own; it is read-only.

**Non-custodial.** NFTs stay in the seller's wallet until a sale settles. Offers and collection bids are escrowed in the contract and can be withdrawn by the bidder at any time.

**What you can do**

- List a token at a fixed price with an expiry.
- Buy a listed token at exactly its price.
- Make an offer on one token, or a collection bid on any token.
- Accept offers and bids as the owner, with a minimum-amount guard.
- Withdraw any payout that couldn't be pushed directly.

**Fees.** Each sale pays a 5% market fee and a 5% creator royalty. The seller receives about 90%. The contract hard-caps the market fee at 5% and the royalty it honors at 10%; the NFT contract itself caps its royalty at 5%.

## 5. Contracts

| Contract | Address |
|---|---|
| Floppy Agents (NFT) | `0x8F1E4787f131990d793Af253d118aed7Fe1B29AF` |
| Floppy Market | `0xf7480360Dcb56543349E7D43c093870d4ede5d5b` |

Both contracts are **verified on BscScan (Exact Match)** and on **Sourcify**, compiled with solc 0.8.24 and 200 optimizer runs. Full source, tests and a Slither static-analysis report are public at github.com/lin1717/floppy-agents-contracts.

### What the owners can and cannot do

**NFT contract owner can:** mint from the 33-token creator reserve, and change the royalty receiver or rate up to 5%.

**NFT contract owner cannot:** raise the supply above 3,333, charge for the mint, change art or traits after mint, or move anyone's tokens.

**Market owner can:** change the fee up to 5%, change the fee recipient, and pause new listings, sales, offers and bids.

**Market owner cannot:** take escrowed funds or NFTs. Bidders can always withdraw their offers and bids, even while the market is paused.

### Security status

The contracts are verified, open-source and covered by unit tests and mainnet-fork tests. They have **not** been audited by an independent firm. Use them at your own risk.

## 6. Community

- X: @Floppyagents
- Email: floppyagents@gmail.com
- Also tradable on Element (element.market)

## 7. What's next

These are plans, not promises:

- Showcase real agent-to-agent trades on Floppy Market.
- More tutorials for agent wallet users, in English and Chinese.
- Community giveaways for active holders.
- Pursue an independent audit when it becomes feasible.

## 8. Disclaimer

Floppy Agents NFTs are digital collectibles. They are not securities, shares, or financial products, and they give no rights to income, governance or future tokens. Prices can go to zero. Nothing here is financial advice. Smart contracts carry risk, including bugs, and these contracts have not been independently audited. Always simulate transactions and check contract addresses before you sign.
