import 'dotenv/config'
import { banner, demoComplete, sectionDivider, info } from './logger.js'
import { DEFAULT_TIER, type TierKey } from './config.js'
import { mintTradingCredential }  from './steps/step1_mintTrading.js'
import { waitForTradingCallback } from './steps/step2_waitTradingCallback.js'
import { executeSwap }            from './steps/step3_swap.js'
import { mintLPCredential }       from './steps/step4_mintLP.js'
import { waitForLPCallback }      from './steps/step5_waitLPCallback.js'
import { addLiquidity }           from './steps/step6_addLiquidity.js'
import { revokeAndWithdraw }      from './steps/step7_revokeAndWithdraw.js'

const args   = process.argv.slice(2)
const filter = args.find(a => a.startsWith('--only='))?.split('=')[1]
const run    = (seg: string) => !filter || filter === seg || filter === 'all'

// --tier=bronze|silver|gold (default: silver)
const tierArg = args.find(a => a.startsWith('--tier='))?.split('=')[1] as TierKey | undefined
const tier: TierKey = tierArg && ['bronze', 'silver', 'gold'].includes(tierArg)
  ? tierArg
  : DEFAULT_TIER

async function main() {
  banner()
  info(`Using ${tier.toUpperCase()} tier institution`)

  if (run('trading')) {
    await mintTradingCredential(tier)
    sectionDivider()
    await waitForTradingCallback(tier)
    sectionDivider()
    await executeSwap(tier)
    sectionDivider()
  }

  if (run('lp')) {
    await mintLPCredential(tier)
    sectionDivider()
    await waitForLPCallback(tier)
    sectionDivider()
    await addLiquidity(tier)
    sectionDivider()
  }

  if (run('revoke') || run('fees')) {
    await revokeAndWithdraw(tier)
    sectionDivider()
  }

  demoComplete()
}

main().catch(err => {
  console.error('\n Demo failed:', err.message)
  process.exit(1)
})
