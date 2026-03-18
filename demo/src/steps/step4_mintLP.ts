import { type Abi } from 'viem'
import { baseOperator, basePublic } from '../clients.js'
import { CONTRACTS, INSTITUTION_ADDRESS } from '../config.js'
import { step, success, txLink, stateTable } from '../logger.js'
import LPMembershipNFTABI from '../../abis/LPMembershipNFT.json' assert { type: 'json' }

export async function mintLPCredential() {
  step(4, 'Minting LP Credential (LPMembershipNFT) — Base Sepolia')

  stateTable('State before LP mint', [
    ['Chain',        'Base Sepolia (84532)'],
    ['Institution',  INSTITUTION_ADDRESS],
    ['Is LP member', 'false'],
  ])

  const hash = await baseOperator.writeContract({
    address: CONTRACTS.base.lpMembershipNFT,
    abi: LPMembershipNFTABI as Abi,
    functionName: 'grantLPMembership',
    args: [INSTITUTION_ADDRESS],
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
