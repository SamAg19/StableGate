import { encodeAbiParameters, formatUnits, parseAbiParameters, type Abi } from 'viem'
import { getInstitutionClient, unichainPublic } from '../clients.js'
import { CONTRACTS, type TierKey, getInstitution } from '../config.js'
import { step, info, success, txLink, stateTable } from '../logger.js'
import { approveToken, readReserves, buildAddLiquidityCalldata } from '../utils.js'
import PositionManagerABI from '../../abis/PositionManager.json' assert { type: 'json' }

const LP_AMOUNT = 50_000n * 10n ** 6n // 50,000 each token

export async function addLiquidity(tier: TierKey) {
  const inst   = getInstitution(tier)
  const client = getInstitutionClient(tier)
  step(6, `Adding liquidity to StableGate pool (${inst.tierName} institution) — Unichain Sepolia`)

  const [r0Before, r1Before] = await readReserves()
  stateTable('Pool reserves before', [
    ['USDC reserve',   formatUnits(r0Before, 6) + ' USDC'],
    ['USDT0 reserve',  formatUnits(r1Before, 6) + ' USDT0'],
    ['LP whitelisted', 'true'],
    ['Institution',    inst.address],
  ])

  // Approve both tokens for position manager
  await approveToken(client, CONTRACTS.unichain.usdc,  CONTRACTS.unichain.positionManager, LP_AMOUNT)
  await approveToken(client, CONTRACTS.unichain.usdt0, CONTRACTS.unichain.positionManager, LP_AMOUNT)
  info('Both tokens approved for Position Manager')

  // hookData encodes LP address for beforeAddLiquidity whitelist check
  const hookData = encodeAbiParameters(
    parseAbiParameters('address'),
    [inst.address]
  )

  const calldata = buildAddLiquidityCalldata(LP_AMOUNT, hookData)
  const hash = await client.writeContract({
    address: CONTRACTS.unichain.positionManager,
    abi: PositionManagerABI as Abi,
    functionName: 'modifyLiquidities',
    args: [calldata],
  })
  txLink('Add liquidity tx (Unichain Sepolia)', hash, 'unichain')
  await unichainPublic.waitForTransactionReceipt({ hash })

  const [r0After, r1After] = await readReserves()
  stateTable('Pool reserves after', [
    ['USDC reserve',  formatUnits(r0After, 6) + ' USDC'],
    ['USDT0 reserve', formatUnits(r1After, 6) + ' USDT0'],
    ['USDC added',    formatUnits(r0After - r0Before, 6)],
    ['USDT0 added',   formatUnits(r1After - r1Before, 6)],
  ])

  success('Liquidity added — institution is now an active LP earning swap fees')
}
