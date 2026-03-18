import 'dotenv/config'
import { banner, demoComplete, sectionDivider } from './logger.js'
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

async function main() {
  banner()

  if (run('trading')) {
    await mintTradingCredential()
    sectionDivider()
    await waitForTradingCallback()
    sectionDivider()
    await executeSwap()
    sectionDivider()
  }

  if (run('lp')) {
    await mintLPCredential()
    sectionDivider()
    await waitForLPCallback()
    sectionDivider()
    await addLiquidity()
    sectionDivider()
  }

  if (run('revoke') || run('fees')) {
    await revokeAndWithdraw()
    sectionDivider()
  }

  demoComplete()
}

main().catch(err => {
  console.error('\n Demo failed:', err.message)
  process.exit(1)
})
