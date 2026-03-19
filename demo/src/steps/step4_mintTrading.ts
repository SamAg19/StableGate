import { type Abi } from 'viem'
import { baseOperator, basePublic } from '../clients.js'
import { CONTRACTS, type TierKey, getInstitution } from '../config.js'
import { step, success, txLink, stateTable } from '../logger.js'
import MembershipNFTABI from '../../abis/MembershipNFT.json' assert { type: 'json' }

export async function mintTradingCredential(tier: TierKey) {
  const inst = getInstitution(tier)
  step(4, `Minting Trading Credential (MembershipNFT, ${inst.tierName} tier) — Base Sepolia`)

  const wasMember = await basePublic.readContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'isMember',
    args: [inst.address],
  }) as boolean

  stateTable('State before mint', [
    ['Chain',        'Base Sepolia (84532)'],
    ['Institution',  inst.address],
    ['Tier',         inst.tierName],
    ['Is member',    String(wasMember)],
  ])

  // Mint with specified tier (Bronze=0, Silver=1, Gold=2)
  const hash = await baseOperator.writeContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'grantMembershipWithTier',
    args: [inst.address, inst.tier],
  })
  txLink('Mint tx (Base Sepolia)', hash, 'base')
  await basePublic.waitForTransactionReceipt({ hash })

  // Read token ID and expiry that were just set
  const nextId = await basePublic.readContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'nextTokenId',
    args: [],
  }) as bigint
  const tokenId = nextId - 1n
  const expiry = await basePublic.readContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'tokenExpiry',
    args: [tokenId],
  }) as bigint

  stateTable('State after mint', [
    ['Is member',      'true'],
    ['Token ID',       String(tokenId)],
    ['Tier',           inst.tierName],
    ['Expires',        new Date(Number(expiry) * 1000).toISOString()],
    ['Events emitted', 'Transfer + TierUpdated + ExpirySet'],
  ])

  success(`MembershipNFT minted (${inst.tierName}) — 3 events emitted, RSC now processing`)
}
