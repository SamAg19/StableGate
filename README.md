# StableGate

KYC-gated stablecoin swap infrastructure. Institutions earn verified access to a 1:1 CSMM (Constant Sum Market Maker) for USDC/USDT0 on Unichain by minting a MembershipNFT on Base — automatically allowlisted by Reactive Network with zero manual steps.

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
| `src/MembershipNFT.sol` | ERC721 membership token. Admin mints to grant access. Burned to revoke. |
| `src/PermissionedCSMMHook.sol` | Uniswap v4 hook with allowlist gate and Constant Sum Market Maker (1:1 pricing). |
| `src/AllowlistReactiveContract.sol` | Reactive Smart Contract (RSC) deployed on Reactive Lasna. Monitors Base for NFT mints and triggers Unichain callbacks. |

## How It Works

1. **Credential issuance (Base):** Admin calls `MembershipNFT.grantMembership(institution)` — mints an ERC721 token.
2. **Cross-chain detection (Reactive Lasna):** The RSC's `react()` is called by ReactVM when the Transfer event is detected on Base. It emits a `Callback` event targeting the Unichain hook.
3. **Allowlisting (Unichain):** Reactive Network's callback proxy delivers the callback by calling `hook.addToAllowlistReactive(rvmId, institution)`.
4. **Gated swap (Unichain):** Institution swaps USDC ↔ USDT0 at 1:1 via the CSMM hook. Non-allowlisted addresses revert.
5. **Revocation:** Owner calls `hook.removeFromAllowlist(institution)` — immediately blocks future swaps.

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
- MembershipNFT minted on Base fork
- `RSC.react()` processes the Base Transfer log and emits the Callback event
- Reactive callback delivered to Unichain hook (simulated via `vm.prank(REACTIVE_CALLBACK_PROXY)`)
- CSMM swap: 10,000 USDC → 10,000 USDT0 at exactly 1:1
- Reverse swap: 5,000 USDT0 → 5,000 USDC at exactly 1:1
- Revoked institution blocked from further swaps

### Run all tests

```bash
forge test -vvv
```

Expected: **38 tests pass** (9 MembershipNFT + 18 hook + 5 RSC + 4 fork + 2 MembershipNFT tests = 38 total).

## Deployment

### Step 1 — Base Sepolia: deploy MembershipNFT

```bash
source .env
forge script script/DeployBase.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvv
```

Note the `MEMBERSHIP_NFT` address and set it in `.env`.

### Step 2 — Unichain Sepolia: deploy PermissionedCSMMHook

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
# Mint NFT on Base Sepolia
cast send $MEMBERSHIP_NFT "grantMembership(address)" $INSTITUTION \
  --rpc-url $BASE_SEPOLIA_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY

# Wait ~30 seconds for Reactive Network to deliver the callback

# Check allowlist on Unichain Sepolia
cast call $HOOK_CONTRACT "isAllowlisted(address)" $INSTITUTION \
  --rpc-url $UNICHAIN_SEPOLIA_RPC
```

## Sponsor Tracks

| Sponsor | Integration |
|---------|-------------|
| **Unichain** | Hook deployed on Unichain, USDC/USDT0 pool, mainnet fork tests |
| **Reactive Network** | Cross-chain NFT-mint → allowlist automation via RSC on Reactive Lasna |

## License

MIT
