# StableGate

KYC-gated stablecoin swap infrastructure. Institutions earn verified access to a CSMM (Constant Sum Market Maker) for USDC/USDT0 on Unichain by minting a tiered MembershipNFT on Base — automatically allowlisted by Reactive Network with zero manual steps. Memberships carry per-tier fees, expiry timestamps, and daily volume caps.

## Architecture

```
Base Mainnet                 Reactive Lasna               Unichain Mainnet
────────────────             ──────────────────           ───────────────────────────────
 MembershipNFT               AllowlistReactive            PermissionedCSMMHook
      │                         Contract                       │
      │  ERC721 Transfer   ┌────────────────┐             ┌───┴────────────────────┐
      │──────────────────► │ react(LogRecord)│             │ addToAllowlistReactive │
      │   (mint event)     │    ↓            │             │         │              │
      │                    │ emit Callback   │────────────►│ allowlist[institution] │
      │                    └────────────────┘  Reactive   │         │              │
      │                     monitors Base,     callback   │   beforeSwap           │
      │                     callbacks Unichain             │   checks allowlist     │
      │                                                    │   executes 1:1 CSMM   │
      │                                                    └───────────────────────┘
```

**Chain roles:**

| Chain | Contract | Role |
|-------|----------|------|
| Base | `MembershipNFT` | Credential issuance — admin mints ERC721 to institution |
| Reactive Lasna | `AllowlistReactiveContract` | Event listener — detects Base mints, triggers Unichain callbacks |
| Unichain | `PermissionedCSMMHook` | Uniswap v4 hook — enforces allowlist, executes 1:1 CSMM swaps |

## Contracts

| Contract | Description |
|----------|-------------|
| `src/interfaces/IStableGate.sol` | Shared `Tier` enum, custom errors, and events used across all contracts. |
| `src/MembershipNFT.sol` | ERC721 credential. Admin mints with tier (Bronze/Silver/Gold) and expiry. Non-transferable. |
| `src/PermissionedCSMMHook.sol` | Uniswap v4 hook — allowlist gate, tier-based fees, expiry enforcement, daily volume caps. |
| `src/AllowlistReactiveContract.sol` | RSC on Reactive Lasna. Monitors Base Transfer + TierUpdated events; auto-allowlists, auto-revokes, and forwards tier to hook. |

## Features

| Feature | Description |
|---------|-------------|
| **Permissioned CSMM** | Only allowlisted institutions can swap USDC ↔ USDT0 via the 1:1 constant-sum hook. |
| **Tiered Fees** | Gold = 0 bps, Silver = 1 bps, Bronze = 3 bps. Applied per-swap from the output amount. |
| **Membership Expiry** | Tokens carry an expiry timestamp. Expired memberships revert on swap with `MembershipExpired`. |
| **Daily Volume Caps** | Per-institution and global daily swap limits with block-based rolling window reset. |
| **Auto-Revocation** | NFT burn or transfer on Base → RSC emits revocation callback → hook removes from allowlist. |
| **Tier Forwarding** | `TierUpdated` events on Base → RSC emits `setInstitutionTier` callback → hook applies fee tier. |

## How It Works

1. **Credential issuance (Base):** Admin calls `MembershipNFT.grantMembershipWithTier(institution, tier)` — mints ERC721 with tier and expiry.
2. **Cross-chain detection (Reactive Lasna):** RSC's `react()` fires on Transfer (mint → allowlist, burn/transfer → revoke) and TierUpdated (forward tier to hook).
3. **Allowlisting + Tier (Unichain):** Reactive Network delivers callbacks: `addToAllowlistReactive` and `setInstitutionTier`.
4. **Gated swap (Unichain):** Institution swaps USDC ↔ USDT0. Hook checks allowlist, expiry, daily cap, applies tier fee, executes CSMM.
5. **Auto-Revocation:** Burning the NFT on Base automatically removes the institution from the Unichain hook allowlist.

## Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git with submodules

### Install

```bash
git clone <repo-url>
cd StableGate
git submodule update --init --recursive
forge build
```

### Environment

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

Required variables:

```
DEPLOYER_ADDRESS=0x...
DEPLOYER_PRIVATE_KEY=0x...

# RPC endpoints
BASE_SEPOLIA_RPC=https://sepolia.base.org
UNICHAIN_SEPOLIA_RPC=https://sepolia.unichain.org
REACTIVE_LASNA_RPC=https://kopli-rpc.rkt.ink

# Set after deploying Base + Unichain (required for DeployReactive)
MEMBERSHIP_NFT=0x...
HOOK_CONTRACT=0x...
```

## Tests

### Unit tests

```bash
forge test --match-contract "MembershipNFTTest|PermissionedCSMMHookTest|AllowlistReactiveContractTest" -vvv
```

### Multi-chain fork demo

Forks both Base mainnet and Unichain mainnet. Runs the full StableGate lifecycle with real USDC and USDT0.

```bash
forge test --match-contract ForkDemoTest -vvv
```

**What the fork demo proves:**

- Non-allowlisted swap rejected on Unichain
- MembershipNFT minted on Base fork; RSC.react() emits Callback
- Reactive callback delivered to Unichain hook (simulated via `vm.prank(REACTIVE_CALLBACK_PROXY)`)
- Gold tier: 10,000 USDC → 10,000 USDT0 at exactly 1:1 (zero fee)
- Bronze tier: 10,000 USDC → 9,997 USDT0 (3 bps fee)
- Reverse swap: 5,000 USDT0 → 5,000 USDC (Gold tier, 1:1)
- Expired membership reverts with `MembershipExpired`
- Daily volume cap enforced: second 10k swap blocked at 15k limit
- Revoked institution blocked from further swaps

### Run all tests

```bash
forge test -vvv
```

Expected: **151 tests pass** (22 MembershipNFT + 11 LPMembershipNFT + 71 hook + 22 RSC + 10 mock tokens + 2 deploy + 13 fork = 151 total).

## Testnet Tokens

StableGate testnet uses `MockUSDC` and `MockUSDT0` — self-controlled ERC20s with public mint, 6 decimals, identical interface to real USDC/USDT0. Deployed by `DeployBase.s.sol` alongside the NFT contracts. No faucets needed.

- Operator receives 500,000 USDC + 500,000 USDT0 at deploy time (for pool seeding)
- Institution receives 100,000 USDC + 100,000 USDT0 at deploy time (for demo swaps and LP)

Top up mid-demo:
```bash
cast send $USDC_ADDRESS "mint(address,uint256)" $INSTITUTION_ADDRESS 50000000000 \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $DEPLOYER_PRIVATE_KEY
```

ForkDemo integration tests continue using real mainnet USDC/USDT0 via `vm.createSelectFork`.

## Deployment

### Step 1 — Base Sepolia: deploy credentials + mock tokens

```bash
source .env
forge script script/DeployBase.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvv
```

Note `MEMBERSHIP_NFT`, `LP_MEMBERSHIP_NFT`, `USDC_ADDRESS`, `USDT0_ADDRESS` and set them in `.env`.

### Step 2 — Unichain Sepolia: deploy PermissionedCSMMHook

Requires `USDC_ADDRESS` and `USDT0_ADDRESS` from Step 1.

```bash
forge script script/DeployUnichain.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvv
```

Note the `HOOK_CONTRACT` address and set it in `.env`.

### Step 3 — Reactive Lasna: deploy AllowlistReactiveContract

Fund your deployer with lREACT first (send SepETH to `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`).

```bash
forge script script/DeployReactive.s.sol \
  --rpc-url $REACTIVE_LASNA_RPC \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvv
```

### Step 4 — Verify the live cross-chain flow

```bash
# Mint Gold NFT on Base Sepolia
cast send $MEMBERSHIP_NFT "grantMembershipWithTier(address,uint8)" $INSTITUTION 2 \
  --rpc-url $BASE_SEPOLIA_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY

# Wait ~30 seconds for Reactive Network to deliver the callback

# Check allowlist on Unichain Sepolia
cast call $HOOK_CONTRACT "isAllowlisted(address)" $INSTITUTION \
  --rpc-url $UNICHAIN_SEPOLIA_RPC

# Check tier (0=Bronze, 1=Silver, 2=Gold)
cast call $HOOK_CONTRACT "institutionTier(address)" $INSTITUTION \
  --rpc-url $UNICHAIN_SEPOLIA_RPC
```

## Sponsor Tracks

| Sponsor | Integration |
|---------|-------------|
| **Unichain** | Hook deployed on Unichain, USDC/USDT0 pool, tier-based CSMM fees, mainnet fork tests |
| **Reactive Network** | Multi-subscription RSC: auto-allowlist on mint, auto-revoke on burn/transfer, tier forwarding on TierUpdated |

## License

MIT
