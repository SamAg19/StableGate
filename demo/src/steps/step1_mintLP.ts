import { type Abi } from 'viem'
import { baseOperator, basePublic } from '../clients.js'
import { CONTRACTS, type TierKey, getInstitution } from '../config.js'
import { step, success, txLink, stateTable } from '../logger.js'
import LPMembershipNFTABI from '../../abis/LPMembershipNFT.json' assert { type: 'json' }

export async function mintLPCredential(tier: TierKey) {
  const inst = getInstitution(tier)
  step(1, `Minting LP Credential (LPMembershipNFT) for ${inst.tierName} institution — Base Sepolia`)

  stateTable('State before LP mint', [
    ['Chain',        'Base Sepolia (84532)'],
    ['Institution',  inst.address],
    ['Is LP member', 'false'],
  ])

  const hash = await baseOperator.writeContract({
    address: CONTRACTS.base.lpMembershipNFT,
    abi: LPMembershipNFTABI as Abi,
    functionName: 'grantLPMembership',
    args: [inst.address],
  })
  txLink('LP mint tx (Base Sepolia)', hash, 'base')
  await basePublic.waitForTransactionReceipt({ hash })

  const nextId = await basePublic.readContract({
    address: CONTRACTS.base.lpMembershipNFT,
    abi: LPMembershipNFTABI as Abi,
    functionName: 'nextTokenId',
    args: [],
  }) as bigint

  stateTable('State after LP mint', [
    ['Is LP member',    'true'],
    ['Token ID',        String(nextId - 1n)],
    ['Event emitted',   'Transfer(0x0 -> institution) from LPMembershipNFT'],
    ['RSC routing',     'log._contract == LP_MEMBERSHIP_NFT -> addToLPWhitelist callback'],
  ])

  success('LPMembershipNFT minted — RSC routing via log._contract')
}
