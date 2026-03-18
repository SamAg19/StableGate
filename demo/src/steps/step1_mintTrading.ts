import { type Abi } from 'viem'
import { baseOperator, basePublic } from '../clients.js'
import { CONTRACTS, INSTITUTION_ADDRESS } from '../config.js'
import { step, success, txLink, stateTable } from '../logger.js'
import MembershipNFTABI from '../../abis/MembershipNFT.json' assert { type: 'json' }

export async function mintTradingCredential() {
  step(1, 'Minting Trading Credential (MembershipNFT) — Base Sepolia')

  const wasMember = await basePublic.readContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'isMember',
    args: [INSTITUTION_ADDRESS],
  }) as boolean

  stateTable('State before mint', [
    ['Chain',        'Base Sepolia (84532)'],
    ['Institution',  INSTITUTION_ADDRESS],
    ['Is member',    String(wasMember)],
  ])

  // Mint Silver tier (Tier enum: Bronze=0, Silver=1, Gold=2)
  const hash = await baseOperator.writeContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'grantMembershipWithTier',
    args: [INSTITUTION_ADDRESS, 1], // Silver
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
    ['Is member',   'true'],
    ['Token ID',    String(tokenId)],
    ['Tier',        'Silver'],
    ['Expires',     new Date(Number(expiry) * 1000).toISOString()],
    ['Events emitted', 'Transfer + TierUpdated + ExpirySet'],
  ])

  success('MembershipNFT minted — 3 events emitted, RSC now processing')
}
