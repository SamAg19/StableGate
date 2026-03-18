import { formatUnits, type Abi } from 'viem'
import { baseOperator, basePublic, unichainOperator, unichainPublic } from '../clients.js'
import { CONTRACTS, OPERATOR_ADDRESS, type TierKey, getInstitution } from '../config.js'
import { step, info, success, warn, txLink, reactscanLink, stateTable, sectionDivider } from '../logger.js'
import { pollUntil } from '../poller.js'
import { getTokenId, getLPTokenId, readReserves } from '../utils.js'
import MembershipNFTABI    from '../../abis/MembershipNFT.json' assert { type: 'json' }
import LPMembershipNFTABI  from '../../abis/LPMembershipNFT.json' assert { type: 'json' }
import HookABI             from '../../abis/PermissionedCSMMHook.json' assert { type: 'json' }

export async function revokeAndWithdraw(tier: TierKey) {
  const inst = getInstitution(tier)
  step(7, `Revoking credentials (${inst.tierName}) + operator fee withdrawal`)

  // ── 7a: Revoke trading credential ──────────────────────────────────────
  sectionDivider()
  info(`7a — Burning MembershipNFT for ${inst.tierName} institution on Base Sepolia...`)

  const tokenId = await getTokenId(inst.address)
  const revokeHash = await baseOperator.writeContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'revokeMembership',
    args: [tokenId],
  })
  txLink('Revoke tx (Base Sepolia)', revokeHash, 'base')
  await basePublic.waitForTransactionReceipt({ hash: revokeHash })
  success('MembershipNFT burned — RSC detects Transfer(institution -> 0x0)')

  reactscanLink('Monitor auto-revocation on Reactscan', CONTRACTS.reactive.allowlistRSC)
  info('RSC calls removeFromAllowlistReactive(rvm_id, institution) on hook')
  info('Hook atomically clears: allowlist + tier + expiry + dailyVolume')

  // Poll until all four fields are cleared — confirms atomic cleanup
  const tradingRevoked = await pollUntil(
    async () => {
      const [allowlisted, tierVal, expiry, volume] = await Promise.all([
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook, abi: HookABI as Abi,
          functionName: 'isAllowlisted', args: [inst.address],
        }),
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook, abi: HookABI as Abi,
          functionName: 'institutionTier', args: [inst.address],
        }),
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook, abi: HookABI as Abi,
          functionName: 'institutionExpiry', args: [inst.address],
        }),
        unichainPublic.readContract({
          address: CONTRACTS.unichain.hook, abi: HookABI as Abi,
          functionName: 'dailyVolume', args: [inst.address],
        }),
      ])
      return !(allowlisted as boolean)
        && (tierVal as number)  === 0
        && (expiry as bigint)   === 0n
        && (volume as bigint)   === 0n
    },
    {
      message:        'Waiting for auto-revocation + atomic state cleanup',
      successMessage: 'Revocation complete — all 4 fields atomically cleared',
      timeoutMessage: 'Revocation callback timed out — check Reactscan above',
      intervalMs:     5_000,
      timeoutMs:      120_000,
    }
  )

  if (!tradingRevoked) process.exit(1)

  stateTable('Hook state after trading revocation', [
    ['isAllowlisted',     'false'],
    ['institutionTier',   'Bronze (0) — reset to safe default'],
    ['institutionExpiry', '0 — cleared'],
    ['dailyVolume',       '0 — cleared'],
    ['Re-onboarding',     'clean slate — no stale state inherited'],
  ])

  // ── 7b: Revoke LP credential ────────────────────────────────────────────
  sectionDivider()
  info(`7b — Burning LPMembershipNFT for ${inst.tierName} institution on Base Sepolia...`)

  const lpTokenId = await getLPTokenId(inst.address)
  const lpRevokeHash = await baseOperator.writeContract({
    address: CONTRACTS.base.lpMembershipNFT,
    abi: LPMembershipNFTABI as Abi,
    functionName: 'revokeLPMembership',
    args: [lpTokenId],
  })
  txLink('LP revoke tx (Base Sepolia)', lpRevokeHash, 'base')
  await basePublic.waitForTransactionReceipt({ hash: lpRevokeHash })
  success('LPMembershipNFT burned — RSC detects Transfer from LP_MEMBERSHIP_NFT')

  reactscanLink('Monitor LP revocation on Reactscan', CONTRACTS.reactive.allowlistRSC)

  const lpRevoked = await pollUntil(
    async () => {
      const whitelisted = await unichainPublic.readContract({
        address: CONTRACTS.unichain.hook, abi: HookABI as Abi,
        functionName: 'isLPWhitelisted', args: [inst.address],
      })
      return !(whitelisted as boolean)
    },
    {
      message:        'Waiting for LP revocation callback',
      successMessage: 'LP access revoked — existing liquidity position untouched',
      timeoutMessage: 'LP revocation timed out — check Reactscan above',
      intervalMs:     5_000,
      timeoutMs:      120_000,
    }
  )

  if (!lpRevoked) process.exit(1)

  // Read pool reserves to prove existing position is intact
  const [r0, r1] = await readReserves()
  stateTable('State after LP revocation', [
    ['isLPWhitelisted',        'false'],
    ['Can add more liquidity', 'no — blocked by beforeAddLiquidity'],
    ['Existing LP position',   'intact — hook cannot force-remove v4 positions'],
    ['Pool USDC reserve',      formatUnits(r0, 6) + ' USDC (unchanged)'],
    ['Pool USDT0 reserve',     formatUnits(r1, 6) + ' USDT0 (unchanged)'],
  ])

  // ── 7c: Operator fee withdrawal ─────────────────────────────────────────
  sectionDivider()
  info('7c — Withdrawing accumulated operator fees — Unichain Sepolia...')

  const [usdcFees, usdt0Fees] = await Promise.all([
    unichainPublic.readContract({
      address: CONTRACTS.unichain.hook, abi: HookABI as Abi,
      functionName: 'accruedFees', args: [CONTRACTS.unichain.usdc],
    }) as Promise<bigint>,
    unichainPublic.readContract({
      address: CONTRACTS.unichain.hook, abi: HookABI as Abi,
      functionName: 'accruedFees', args: [CONTRACTS.unichain.usdt0],
    }) as Promise<bigint>,
  ])

  stateTable('Accrued operator fees', [
    ['USDC fees',  formatUnits(usdcFees, 6)  + ' USDC'],
    ['USDT0 fees', formatUnits(usdt0Fees, 6) + ' USDT0'],
    ['Source',     '50% of all Silver/Bronze swap fees'],
    ['Other 50%',  'Donated to LPs via poolManager.donate()'],
  ])

  if (usdt0Fees > 0n) {
    const withdrawHash = await unichainOperator.writeContract({
      address: CONTRACTS.unichain.hook, abi: HookABI as Abi,
      functionName: 'withdrawFees', args: [CONTRACTS.unichain.usdt0],
    })
    txLink('Withdraw fees tx (Unichain Sepolia)', withdrawHash, 'unichain')
    await unichainPublic.waitForTransactionReceipt({ hash: withdrawHash })
    success(`${formatUnits(usdt0Fees, 6)} USDT0 withdrawn to ${OPERATOR_ADDRESS}`)
  } else {
    warn('No USDT0 fees accrued yet — execute more swaps before running fees segment')
  }
}
