import 'dotenv/config'
import { banner, demoComplete, sectionDivider, info, warn } from './logger.js'
import { DEFAULT_TIER, type TierKey } from './config.js'
import { loadSnapshot, saveSnapshot, clearSnapshot } from './snapshot.js'
import { mintLPCredential }       from './steps/step1_mintLP.js'
import { waitForLPCallback }      from './steps/step2_waitLPCallback.js'
import { addLiquidity }           from './steps/step3_addLiquidity.js'
import { mintTradingCredential }  from './steps/step4_mintTrading.js'
import { waitForTradingCallback } from './steps/step5_waitTradingCallback.js'
import { executeSwap }            from './steps/step6_swap.js'
import { revokeAndWithdraw }      from './steps/step7_revokeAndWithdraw.js'

const args   = process.argv.slice(2)
const filter = args.find(a => a.startsWith('--only='))?.split('=')[1]
const fresh  = args.includes('--fresh')
const run    = (seg: string) => !filter || filter === seg || filter === 'all'

// --tier=bronze|silver|gold (default: silver)
const tierArg = args.find(a => a.startsWith('--tier='))?.split('=')[1] as TierKey | undefined
const tier: TierKey = tierArg && ['bronze', 'silver', 'gold'].includes(tierArg)
  ? tierArg
  : DEFAULT_TIER

// Steps in order with their segment assignment
const steps = [
  { num: 1, seg: 'lp',      fn: mintLPCredential },
  { num: 2, seg: 'lp',      fn: waitForLPCallback },
  { num: 3, seg: 'lp',      fn: addLiquidity },
  { num: 4, seg: 'trading',  fn: mintTradingCredential },
  { num: 5, seg: 'trading',  fn: waitForTradingCallback },
  { num: 6, seg: 'trading',  fn: executeSwap },
  { num: 7, seg: 'revoke',   fn: revokeAndWithdraw },
] as const

async function main() {
  banner()
  info(`Using ${tier.toUpperCase()} tier institution`)

  // Load snapshot (or start fresh with --fresh flag)
  let lastCompleted = fresh ? 0 : loadSnapshot(tier)
  if (fresh && lastCompleted > 0) {
    warn('--fresh flag: ignoring snapshot, starting from step 1')
    lastCompleted = 0
  }

  for (const { num, seg, fn } of steps) {
    // Skip steps not in the requested segment
    if (!run(seg) && seg !== 'revoke') continue
    // For revoke segment, check both 'revoke' and 'fees'
    if (seg === 'revoke' && !run('revoke') && !run('fees')) continue

    // Skip already-completed steps (from snapshot)
    if (num <= lastCompleted) {
      info(`Step ${num} already completed — skipping`)
      continue
    }

    await fn(tier)
    saveSnapshot(tier, num)
    sectionDivider()
  }

  // All steps done — clear snapshot for next run
  clearSnapshot()
  demoComplete()
}

main().catch(err => {
  console.error('\n Demo failed:', err.message)
  console.error(' Resume with: npm run demo -- --tier=' + tier)
  process.exit(1)
})
