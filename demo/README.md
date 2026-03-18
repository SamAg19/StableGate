# StableGate Demo

## Prerequisites
- Node.js 20+
- All contracts deployed (run `forge script` deployment scripts first)
- Operator wallet funded on Base Sepolia + Unichain Sepolia
- Three institution wallets funded on Unichain Sepolia (ETH for gas only)
- Reactive Lasna: AllowlistReactiveContract deployed and funded with lREACT

## Token Setup (Testnet)

StableGate testnet uses MockUSDC and MockUSDT0 deployed alongside the contracts.
No faucets needed — the deployment script mints initial balances automatically:

- Operator wallet receives 500,000 USDC + 500,000 USDT0 (for pool seeding)
- Each institution wallet receives 100,000 USDC + 100,000 USDT0 (for demo swaps and LP)

If you need to top up balances mid-demo:
```bash
cast send $USDC_ADDRESS "mint(address,uint256)" $INSTITUTION_BRONZE 50000000000 \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY
```
(50000000000 = 50,000 USDC in 6 decimal units)

## Setup
```bash
cd demo
npm install
cp .env.example .env
# Fill in all addresses and private keys for operator + 3 institutions
forge build && npm run extract-abis
```

## Run
```bash
npm run demo                            # full demo with Silver tier (default)
npm run demo -- --tier=bronze           # full demo with Bronze institution
npm run demo -- --tier=gold             # full demo with Gold institution
npm run demo -- --only=trading          # steps 1-3 only
npm run demo -- --only=lp              # steps 4-6 only
npm run demo -- --only=revoke          # step 7 only
npm run demo -- --only=trading --tier=gold  # combine flags
npm run demo:bronze                     # shortcut: full demo with Bronze
npm run demo:silver                     # shortcut: full demo with Silver
npm run demo:gold                       # shortcut: full demo with Gold
```

## Three Institutions

Each tier has its own wallet so you can test all fee levels independently:

| Tier | Fee | Daily Limit | Env vars |
|------|-----|-------------|----------|
| Bronze | 3 bps | 1,000,000 USDC | `INSTITUTION_BRONZE_*` |
| Silver | 1 bps | 5,000,000 USDC | `INSTITUTION_SILVER_*` |
| Gold | 0 bps | Unlimited | `INSTITUTION_GOLD_*` |

## Pre-demo checklist
- [ ] forge build && npm run extract-abis  (after any contract change)
- [ ] All 3 institution wallets have ETH on Unichain Sepolia
- [ ] Operator wallet has ETH on Base Sepolia + Unichain Sepolia
- [ ] AllowlistReactiveContract funded with lREACT on Reactive Lasna
- [ ] ALLOWLIST_REACTIVE_CONTRACT address in .env (for Reactscan links)

## Cross-chain wait times
Reactive Network testnet callbacks typically arrive in 15-45 seconds.
Each polling step times out after 2 minutes.
Open the Reactscan link printed during steps 2 and 5 to show live RSC activity.
