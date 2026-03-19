#!/bin/bash
# Run the full StableGate demo: LP initialization, then all 3 tiers.
#
# Usage:
#   cd demo && bash scripts/run-demo.sh
set -euo pipefail

echo "═══════════════════════════════════════════════════════════"
echo "  StableGate Full Demo — LP + Gold + Silver + Bronze"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Step 1: LP initialization (uses the dedicated LP institution to seed the pool)
echo "──── Phase 1: LP Initialization ────"
npx tsx src/index.ts --only=lp --fresh
echo ""

# Step 2: Gold tier — full trading flow (0 bps fee, unlimited daily cap)
echo "──── Phase 2: Gold Tier Trading ────"
npx tsx src/index.ts --only=trading --tier=gold --fresh
echo ""

# Step 3: Silver tier — full trading flow (1 bps fee, 5M daily cap)
echo "──── Phase 3: Silver Tier Trading ────"
npx tsx src/index.ts --only=trading --tier=silver --fresh
echo ""

# Step 4: Bronze tier — full trading flow (3 bps fee, 1M daily cap)
echo "──── Phase 4: Bronze Tier Trading ────"
npx tsx src/index.ts --only=trading --tier=bronze --fresh
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "  All 4 phases complete!"
echo "═══════════════════════════════════════════════════════════"
