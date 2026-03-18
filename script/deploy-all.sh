#!/bin/bash
# Deploy all StableGate contracts across 3 chains in one command.
#
# Usage:
#   source .env && bash script/deploy-all.sh
#
# Prerequisites:
#   - .env filled with DEPLOYER_ADDRESS, DEPLOYER_PRIVATE_KEY, INSTITUTION_BRONZE/SILVER/GOLD
#   - Operator funded with ETH on Base Sepolia + Unichain Sepolia + lREACT on Reactive Lasna
#   - forge build completed
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}${BOLD}[deploy]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
fail() { echo -e "${RED}  ✗ $1${NC}"; exit 1; }

# ── Validate env ─────────────────────────────────────────────────────────────

required_vars=(
  DEPLOYER_ADDRESS DEPLOYER_PRIVATE_KEY
  INSTITUTION_BRONZE INSTITUTION_SILVER INSTITUTION_GOLD
  BASE_SEPOLIA_RPC UNICHAIN_SEPOLIA_RPC REACTIVE_LASNA_RPC
)
for var in "${required_vars[@]}"; do
  [ -z "${!var:-}" ] && fail "Missing env var: $var"
done
ok "All required env vars present"

# ── Build ────────────────────────────────────────────────────────────────────

log "Building contracts..."
forge build --force --silent
ok "forge build complete"

# ── Step 1: Base Sepolia ─────────────────────────────────────────────────────

log "Step 1/3: Deploying to Base Sepolia (MembershipNFT + LPMembershipNFT)..."

BASE_OUTPUT=$(forge script script/DeployBase.s.sol \
  --rpc-url "$BASE_SEPOLIA_RPC" \
  --broadcast \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  -vvv 2>&1)

# Extract addresses from forge output
MEMBERSHIP_NFT=$(echo "$BASE_OUTPUT" | grep "MEMBERSHIP_NFT=" | head -1 | sed 's/.*MEMBERSHIP_NFT= *//' | tr -d '[:space:]')
LP_MEMBERSHIP_NFT=$(echo "$BASE_OUTPUT" | grep "LP_MEMBERSHIP_NFT=" | head -1 | sed 's/.*LP_MEMBERSHIP_NFT= *//' | tr -d '[:space:]')

[ -z "$MEMBERSHIP_NFT" ] && fail "Failed to extract MEMBERSHIP_NFT address from deploy output"
[ -z "$LP_MEMBERSHIP_NFT" ] && fail "Failed to extract LP_MEMBERSHIP_NFT address from deploy output"

ok "MembershipNFT:    $MEMBERSHIP_NFT"
ok "LPMembershipNFT:  $LP_MEMBERSHIP_NFT"

# Export for subsequent scripts
export MEMBERSHIP_NFT
export LP_MEMBERSHIP_NFT

# ── Step 2: Unichain Sepolia ────────────────────────────────────────────────

log "Step 2/3: Deploying to Unichain Sepolia (MockTokens + Hook + Pool + Liquidity)..."

UNICHAIN_OUTPUT=$(forge script script/DeployUnichain.s.sol \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
  --broadcast \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  -vvv 2>&1)

USDC_ADDRESS=$(echo "$UNICHAIN_OUTPUT" | grep "USDC_ADDRESS=" | head -1 | sed 's/.*USDC_ADDRESS= *//' | tr -d '[:space:]')
USDT0_ADDRESS=$(echo "$UNICHAIN_OUTPUT" | grep "USDT0_ADDRESS=" | head -1 | sed 's/.*USDT0_ADDRESS= *//' | tr -d '[:space:]')
HOOK_CONTRACT=$(echo "$UNICHAIN_OUTPUT" | grep "HOOK_CONTRACT=" | head -1 | sed 's/.*HOOK_CONTRACT= *//' | tr -d '[:space:]')

[ -z "$USDC_ADDRESS" ] && fail "Failed to extract USDC_ADDRESS from deploy output"
[ -z "$USDT0_ADDRESS" ] && fail "Failed to extract USDT0_ADDRESS from deploy output"
[ -z "$HOOK_CONTRACT" ] && fail "Failed to extract HOOK_CONTRACT from deploy output"

ok "MockUSDC:         $USDC_ADDRESS"
ok "MockUSDT0:        $USDT0_ADDRESS"
ok "Hook:             $HOOK_CONTRACT"

export USDC_ADDRESS
export USDT0_ADDRESS
export HOOK_CONTRACT

# ── Step 3: Reactive Lasna ──────────────────────────────────────────────────

log "Step 3/3: Deploying to Reactive Lasna (AllowlistReactiveContract)..."

REACTIVE_OUTPUT=$(forge script script/DeployReactive.s.sol \
  --rpc-url "$REACTIVE_LASNA_RPC" \
  --broadcast \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  -vvv 2>&1)

ALLOWLIST_REACTIVE_CONTRACT=$(echo "$REACTIVE_OUTPUT" | grep "AllowlistReactiveContract:" | head -1 | sed 's/.*AllowlistReactiveContract: *//' | tr -d '[:space:]')

[ -z "$ALLOWLIST_REACTIVE_CONTRACT" ] && fail "Failed to extract AllowlistReactiveContract address from deploy output"

ok "AllowlistRSC:     $ALLOWLIST_REACTIVE_CONTRACT"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}═══ All 3 chains deployed successfully ═══${NC}"
echo ""
echo "Copy these into your .env and demo/.env:"
echo ""
echo "# Base Sepolia"
echo "MEMBERSHIP_NFT=$MEMBERSHIP_NFT"
echo "LP_MEMBERSHIP_NFT=$LP_MEMBERSHIP_NFT"
echo ""
echo "# Unichain Sepolia"
echo "USDC_ADDRESS=$USDC_ADDRESS"
echo "USDT0_ADDRESS=$USDT0_ADDRESS"
echo "HOOK_CONTRACT=$HOOK_CONTRACT"
echo ""
echo "# Reactive Lasna"
echo "ALLOWLIST_REACTIVE_CONTRACT=$ALLOWLIST_REACTIVE_CONTRACT"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Paste the addresses above into .env and demo/.env"
echo "  2. Verify RSC subscriptions: https://reactscan.net/rsc/$ALLOWLIST_REACTIVE_CONTRACT"
echo "  3. Extract ABIs: bash demo/scripts/extract-abis.sh"
echo "  4. Run demo: cd demo && npm run demo"
