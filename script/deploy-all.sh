#!/bin/bash
# Deploy all StableGate contracts across 3 chains in one command.
#
# Usage:
#   bash script/deploy-all.sh              # deploy all 3 chains
#   bash script/deploy-all.sh --reactive   # skip Base + Unichain, deploy only Reactive (uses saved state)
#
# State is saved to deployments.json after Base + Unichain succeed.
# If Reactive fails, re-run with --reactive to retry without redeploying.
#
# Prerequisites:
#   - .env filled with DEPLOYER_ADDRESS, DEPLOYER_PRIVATE_KEY, INSTITUTION_BRONZE/SILVER/GOLD/LP
#   - Operator funded with ETH on Base Sepolia + Unichain Sepolia + lREACT on Reactive Lasna
set -uo pipefail

DEPLOY_STATE="deployments.json"

# ── Load .env (strip comments, blank lines, and export all vars) ─────────────
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  eval "$(grep -v '^\s*#' .env | grep -v '^\s*$' | sed 's/\s*#.*//')"
  set +a
else
  echo "No .env file found — run from repo root"
  exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}${BOLD}[deploy]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}  !${NC} $1"; }
fail() { echo -e "${RED}  ✗ $1${NC}"; exit 1; }

# Run a forge script, show output live, capture into LAST_OUTPUT
run_forge() {
  local label="$1"
  shift
  local tmpfile
  tmpfile=$(mktemp)

  if forge script "$@" 2>&1 | tee "$tmpfile"; then
    LAST_OUTPUT=$(cat "$tmpfile")
    rm -f "$tmpfile"
    return 0
  else
    echo ""
    echo -e "${RED}${BOLD}forge script failed for: ${label}${NC}"
    echo -e "${RED}Output:${NC}"
    cat "$tmpfile"
    rm -f "$tmpfile"
    exit 1
  fi
}

# Save deployment state to JSON
save_state() {
  cat > "$DEPLOY_STATE" <<EOF
{
  "base": {
    "membershipNFT": "$MEMBERSHIP_NFT",
    "lpMembershipNFT": "$LP_MEMBERSHIP_NFT"
  },
  "unichain": {
    "usdc": "$USDC_ADDRESS",
    "usdt0": "$USDT0_ADDRESS",
    "hook": "$HOOK_CONTRACT"
  }
}
EOF
  ok "Deployment state saved to $DEPLOY_STATE"
}

# Load deployment state from JSON
load_state() {
  if [ ! -f "$DEPLOY_STATE" ]; then
    fail "No $DEPLOY_STATE found. Run without --reactive first to deploy Base + Unichain."
  fi

  log "Loading deployment state from $DEPLOY_STATE..."

  MEMBERSHIP_NFT=$(jq -r '.base.membershipNFT' "$DEPLOY_STATE")
  LP_MEMBERSHIP_NFT=$(jq -r '.base.lpMembershipNFT' "$DEPLOY_STATE")
  USDC_ADDRESS=$(jq -r '.unichain.usdc' "$DEPLOY_STATE")
  USDT0_ADDRESS=$(jq -r '.unichain.usdt0' "$DEPLOY_STATE")
  HOOK_CONTRACT=$(jq -r '.unichain.hook' "$DEPLOY_STATE")

  [ "$MEMBERSHIP_NFT" = "null" ] || [ -z "$MEMBERSHIP_NFT" ] && fail "Missing membershipNFT in $DEPLOY_STATE"
  [ "$LP_MEMBERSHIP_NFT" = "null" ] || [ -z "$LP_MEMBERSHIP_NFT" ] && fail "Missing lpMembershipNFT in $DEPLOY_STATE"
  [ "$HOOK_CONTRACT" = "null" ] || [ -z "$HOOK_CONTRACT" ] && fail "Missing hook in $DEPLOY_STATE"

  export MEMBERSHIP_NFT LP_MEMBERSHIP_NFT USDC_ADDRESS USDT0_ADDRESS HOOK_CONTRACT

  ok "MembershipNFT:    $MEMBERSHIP_NFT"
  ok "LPMembershipNFT:  $LP_MEMBERSHIP_NFT"
  ok "MockUSDC:         $USDC_ADDRESS"
  ok "MockUSDT0:        $USDT0_ADDRESS"
  ok "Hook:             $HOOK_CONTRACT"
}

# ── Parse args ───────────────────────────────────────────────────────────────

REACTIVE_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --reactive) REACTIVE_ONLY=true ;;
  esac
done

# ── Validate env ─────────────────────────────────────────────────────────────

required_vars=(
  DEPLOYER_ADDRESS DEPLOYER_PRIVATE_KEY
  INSTITUTION_BRONZE INSTITUTION_SILVER INSTITUTION_GOLD INSTITUTION_LP
  BASE_SEPOLIA_RPC UNICHAIN_SEPOLIA_RPC REACTIVE_LASNA_RPC
)
for var in "${required_vars[@]}"; do
  [ -z "${!var:-}" ] && fail "Missing env var: $var"
done
ok "All required env vars present"

if [ "$REACTIVE_ONLY" = true ]; then
  # ── Reactive-only mode: load state from previous deployment ──────────────
  load_state
else
  # ── Full deployment: Base → Unichain → save state → Reactive ─────────────

  # ── Step 1: Base Sepolia ─────────────────────────────────────────────────

  log "Step 1/3: Deploying to Base Sepolia (MembershipNFT + LPMembershipNFT)..."

  run_forge "DeployBase" script/DeployBase.s.sol \
    --rpc-url "$BASE_SEPOLIA_RPC" \
    --broadcast \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    -vvv

  MEMBERSHIP_NFT=$(echo "$LAST_OUTPUT" | grep "MEMBERSHIP_NFT=" | head -1 | sed 's/.*MEMBERSHIP_NFT= *//' | tr -d '[:space:]')
  LP_MEMBERSHIP_NFT=$(echo "$LAST_OUTPUT" | grep "LP_MEMBERSHIP_NFT=" | head -1 | sed 's/.*LP_MEMBERSHIP_NFT= *//' | tr -d '[:space:]')

  [ -z "$MEMBERSHIP_NFT" ] && fail "Failed to extract MEMBERSHIP_NFT address from deploy output"
  [ -z "$LP_MEMBERSHIP_NFT" ] && fail "Failed to extract LP_MEMBERSHIP_NFT address from deploy output"

  ok "MembershipNFT:    $MEMBERSHIP_NFT"
  ok "LPMembershipNFT:  $LP_MEMBERSHIP_NFT"

  export MEMBERSHIP_NFT LP_MEMBERSHIP_NFT

  echo ""

  # ── Step 2: Unichain Sepolia ──────────────────────────────────────────────

  log "Step 2/3: Deploying to Unichain Sepolia (MockTokens + Hook + Pool)..."

  run_forge "DeployUnichain" script/DeployUnichain.s.sol \
    --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
    --broadcast \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --slow \
    -vvv

  USDC_ADDRESS=$(echo "$LAST_OUTPUT" | grep "USDC_ADDRESS=" | head -1 | sed 's/.*USDC_ADDRESS= *//' | tr -d '[:space:]')
  USDT0_ADDRESS=$(echo "$LAST_OUTPUT" | grep "USDT0_ADDRESS=" | head -1 | sed 's/.*USDT0_ADDRESS= *//' | tr -d '[:space:]')
  HOOK_CONTRACT=$(echo "$LAST_OUTPUT" | grep "HOOK_CONTRACT=" | head -1 | sed 's/.*HOOK_CONTRACT= *//' | tr -d '[:space:]')

  [ -z "$USDC_ADDRESS" ] && fail "Failed to extract USDC_ADDRESS from deploy output"
  [ -z "$USDT0_ADDRESS" ] && fail "Failed to extract USDT0_ADDRESS from deploy output"
  [ -z "$HOOK_CONTRACT" ] && fail "Failed to extract HOOK_CONTRACT from deploy output"

  ok "MockUSDC:         $USDC_ADDRESS"
  ok "MockUSDT0:        $USDT0_ADDRESS"
  ok "Hook:             $HOOK_CONTRACT"

  export USDC_ADDRESS USDT0_ADDRESS HOOK_CONTRACT

  echo ""

  # ── Save state so Reactive can be retried independently ──────────────────
  save_state
fi

echo ""

# ── Step 3: Reactive Lasna ────────────────────────────────────────────────

log "Step 3/3: Deploying to Reactive Lasna (AllowlistReactiveContract)..."

# forge script cannot simulate Reactive Lasna precompiles (0x...0064).
# Use forge create instead — it sends the deploy tx directly without simulation.
REACTIVE_CREATE_OUTPUT=$(forge create \
  --rpc-url "$REACTIVE_LASNA_RPC" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --value 1ether \
  --legacy \
  --broadcast \
  src/AllowlistReactiveContract.sol:AllowlistReactiveContract \
  --constructor-args "$MEMBERSHIP_NFT" "$LP_MEMBERSHIP_NFT" "$HOOK_CONTRACT" \
  2>&1) || {
    echo ""
    echo -e "${RED}${BOLD}forge create failed for Reactive deployment${NC}"
    echo "$REACTIVE_CREATE_OUTPUT"
    exit 1
  }

echo "$REACTIVE_CREATE_OUTPUT"
ALLOWLIST_REACTIVE_CONTRACT=$(echo "$REACTIVE_CREATE_OUTPUT" | grep "Deployed to:" | head -1 | sed 's/.*Deployed to: *//' | tr -d '[:space:]')

[ -z "$ALLOWLIST_REACTIVE_CONTRACT" ] && fail "Failed to extract AllowlistReactiveContract address from deploy output"

ok "AllowlistRSC:     $ALLOWLIST_REACTIVE_CONTRACT"

# Update state file with RSC address
if [ -f "$DEPLOY_STATE" ]; then
  TMP=$(mktemp)
  jq --arg rsc "$ALLOWLIST_REACTIVE_CONTRACT" '. + {reactive: {allowlistRSC: $rsc}}' "$DEPLOY_STATE" > "$TMP" && mv "$TMP" "$DEPLOY_STATE"
  ok "Updated $DEPLOY_STATE with RSC address"
fi

echo ""

# ── Summary ──────────────────────────────────────────────────────────────────

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
echo -e "${CYAN}Saved to:${NC} $DEPLOY_STATE"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Paste the addresses above into .env and demo/.env"
echo "  2. Verify RSC subscriptions: https://lasna.reactscan.net/rsc/$ALLOWLIST_REACTIVE_CONTRACT"
echo "  3. Extract ABIs: bash demo/scripts/extract-abis.sh"
echo "  4. Run demo: cd demo && npm run demo"
