import { type Abi } from 'viem'
import { unichainPublic } from '../clients.js'
import { CONTRACTS, INSTITUTION_ADDRESS } from '../config.js'
import { step, info, reactscanLink, stateTable } from '../logger.js'
import { pollUntil } from '../poller.js'
import HookABI from '../../abis/PermissionedCSMMHook.json' assert { type: 'json' }

export async function waitForTradingCallback() {
  step(2, 'Waiting for Reactive Network callbacks — Unichain Sepolia')

  info('AllowlistReactiveContract on Reactive Lasna detected:')
  info('  Transfer(0x0 -> institution)  ->  addToAllowlistReactive()')
  info('  TierUpdated(institution, 1)   ->  setInstitutionTier()')
  info('  ExpirySet(institution, ts)    ->  setInstitutionExpiry()')

  // Print Reactscan link immediately — presenter opens this in browser
  reactscanLink(
    'Monitor RSC on Reactscan',
    CONTRACTS.reactive.allowlistRSC
  )

  // Poll until ALL THREE callbacks have landed on the hook
  const arrived = await pollUntil(
    async () => {
      const [allowlisted, tier, expiry] = await Promise.all([
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook,
          abi: HookABI as Abi,
          functionName: 'isAllowlisted',
          args: [INSTITUTION_ADDRESS],
        }),
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook,
          abi: HookABI as Abi,
          functionName: 'institutionTier',
          args: [INSTITUTION_ADDRESS],
        }),
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook,
          abi: HookABI as Abi,
          functionName: 'institutionExpiry',
          args: [INSTITUTION_ADDRESS],
        }),
      ])

      const isAllowlisted = allowlisted as boolean
      const tierValue     = tier as number
      const expiryValue   = expiry as bigint

      // All three must be set:
      // allowlist = true, tier = 1 (Silver), expiry > 0
      return isAllowlisted && tierValue === 1 && expiryValue > 0n
    },
    {
      message:        'Waiting for 3 RSC callbacks to land on Unichain Sepolia',
      successMessage: 'All 3 callbacks received: allowlist + tier + expiry',
      timeoutMessage: 'Callbacks timed out — check Reactscan link above',
      intervalMs:     5_000,
      timeoutMs:      120_000,
    }
  )

  if (!arrived) process.exit(1)

  stateTable('Hook state on Unichain Sepolia (post-callback)', [
    ['isAllowlisted',     'true'],
    ['institutionTier',   'Silver (1) — set by RSC callback'],
    ['institutionExpiry', 'set — forwarded from Base Sepolia by RSC'],
    ['dailyLimit',        '5,000,000 USDC (derived from Silver tier)'],
    ['Callbacks received', '3 / 3'],
  ])
}
