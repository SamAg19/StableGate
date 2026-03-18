# StableGate Demo

## Prerequisites
- Node.js 20+
- All contracts deployed (run `forge script` deployment scripts first)
- Operator wallet funded on Base Sepolia + Unichain Sepolia
- Institution wallet funded on Unichain Sepolia (needs USDC + USDT0 + ETH for gas)
- Reactive Lasna: AllowlistReactiveContract deployed and funded with lREACT

## Setup
```bash
cd demo
npm install
cp .env.example .env
# Fill in all addresses and private keys
forge build && npm run extract-abis
```

## Run
```bash
npm run demo                       # full demo — all 7 steps
npm run demo -- --only=trading     # steps 1-3: trading credential lifecycle
npm run demo -- --only=lp          # steps 4-6: LP credential lifecycle
npm run demo -- --only=revoke      # step 7: revocation + fee withdrawal
```

## Pre-demo checklist
- [ ] forge build && npm run extract-abis  (after any contract change)
- [ ] Institution wallet has 50,000+ USDC and USDT0 on Unichain Sepolia
- [ ] Operator wallet has ETH on Base Sepolia + Unichain Sepolia
- [ ] AllowlistReactiveContract funded with lREACT on Reactive Lasna
- [ ] ALLOWLIST_REACTIVE_CONTRACT address in .env (for Reactscan links)

## Cross-chain wait times
Reactive Network testnet callbacks typically arrive in 15-45 seconds.
Each polling step times out after 2 minutes.
Open the Reactscan link printed during steps 2 and 5 to show live RSC activity.
