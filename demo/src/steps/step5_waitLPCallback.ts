import { type Abi } from 'viem'
import { unichainPublic } from '../clients.js'
import { CONTRACTS, INSTITUTION_ADDRESS } from '../config.js'
import { step, info, reactscanLink, stateTable } from '../logger.js'
import { pollUntil } from '../poller.js'
import HookABI from '../../abis/PermissionedCSMMHook.json' assert { type: 'json' }

export async function waitForLPCallback() {
  step(5, 'Waiting for LP RSC callback — Unichain Sepolia')

  info('AllowlistReactiveContract detected Transfer from LPMembershipNFT:')
  info('  log._contract == LPMembershipNFT -> addToLPWhitelist(rvm_id, institution)')

  reactscanLink(
    'Monitor RSC on Reactscan',
    CONTRACTS.reactive.allowlistRSC
  )

  const arrived = await pollUntil(
    async () => {
      const whitelisted = await unichainPublic.readContract({
        address: CONTRACTS.unichain.hook,
        abi: HookABI as Abi,
        functionName: 'isLPWhitelisted',
        args: [INSTITUTION_ADDRESS],
      })
      return whitelisted as boolean
    },
    {
      message:        'Waiting for addToLPWhitelist callback to land on Unichain Sepolia',
      successMessage: 'LP whitelist callback received — institution can now add liquidity',
      timeoutMessage: 'LP callback timed out — check Reactscan link above',
      intervalMs:     5_000,
      timeoutMs:      120_000,
    }
  )

  if (!arrived) process.exit(1)

  stateTable('Hook state after LP callback', [
    ['isLPWhitelisted',  'true'],
    ['Callbacks received', '1 / 1'],
    ['Source',           'Reactive Network (Base Sepolia -> Unichain Sepolia)'],
    ['Routing key',      'log._contract == LP_MEMBERSHIP_NFT'],
  ])
}
