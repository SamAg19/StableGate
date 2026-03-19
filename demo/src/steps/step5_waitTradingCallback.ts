import { type Abi } from 'viem'
import { unichainPublic } from '../clients.js'
import { CONTRACTS, type TierKey, getInstitution } from '../config.js'
import { step, info, success, reactscanLink, stateTable } from '../logger.js'
import { pollUntil } from '../poller.js'
import HookABI from '../../abis/PermissionedCSMMHook.json' assert { type: 'json' }

export async function waitForTradingCallback(tier: TierKey) {
  const inst = getInstitution(tier)
  step(5, `Waiting for Reactive Network callbacks (${inst.tierName} tier) — Unichain Sepolia`)

  // Check if already allowlisted with correct tier (from a previous run)
  const [alreadyAllowlisted, currentTier] = await Promise.all([
    unichainPublic.readContract({
      address: CONTRACTS.unichain.hook,
      abi: HookABI as Abi,
      functionName: 'isAllowlisted',
      args: [inst.address],
    }) as Promise<boolean>,
    unichainPublic.readContract({
      address: CONTRACTS.unichain.hook,
      abi: HookABI as Abi,
      functionName: 'institutionTier',
      args: [inst.address],
    }) as Promise<number>,
  ])

  if (alreadyAllowlisted && currentTier === inst.tier) {
    info(`Institution ${inst.address} is already allowlisted with ${inst.tierName} tier — skipping wait`)
    success('Trading callbacks already landed')
    return
  }

  info('AllowlistReactiveContract on Reactive Lasna detected:')
  info('  Transfer(0x0 -> institution)  ->  addToAllowlistReactive()')
  info(`  TierUpdated(institution, ${inst.tier})   ->  setInstitutionTier()`)
  info('  ExpirySet(institution, ts)    ->  setInstitutionExpiry()')

  // Print Reactscan link immediately — presenter opens this in browser
  reactscanLink(
    'Monitor RSC on Reactscan',
    CONTRACTS.reactive.allowlistRSC
  )

  // Poll until allowlist + tier callbacks have landed on the hook
  const arrived = await pollUntil(
    async () => {
      const [allowlisted, tierValue] = await Promise.all([
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook,
          abi: HookABI as Abi,
          functionName: 'isAllowlisted',
          args: [inst.address],
        }),
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook,
          abi: HookABI as Abi,
          functionName: 'institutionTier',
          args: [inst.address],
        }),
      ])

      return (allowlisted as boolean) && (tierValue as number) === inst.tier
    },
    {
      message:        'Waiting for RSC callbacks to land on Unichain Sepolia',
      successMessage: 'Callbacks received: allowlist + tier confirmed',
      timeoutMessage: 'Callbacks timed out — check Reactscan link above',
      intervalMs:     5_000,
      timeoutMs:      120_000,
    }
  )

  if (!arrived) process.exit(1)

  const dailyLimits: Record<number, string> = {
    0: '1,000,000 USDC (Bronze)',
    1: '5,000,000 USDC (Silver)',
    2: 'Unlimited (Gold)',
  }

  stateTable('Hook state on Unichain Sepolia (post-callback)', [
    ['isAllowlisted',     'true'],
    ['institutionTier',   `${inst.tierName} (${inst.tier}) — set by RSC callback`],
    ['dailyLimit',        dailyLimits[inst.tier] ?? 'unknown'],
    ['Callbacks received', 'allowlist + tier'],
  ])
}
