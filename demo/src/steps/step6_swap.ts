import { encodeAbiParameters, formatUnits, parseAbiParameters, type Abi } from 'viem'
import { getInstitutionClient, unichainPublic } from '../clients.js'
import { CONTRACTS, type TierKey, getInstitution } from '../config.js'
import { step, info, success, txLink, stateTable } from '../logger.js'
import { approveToken, readBalances, buildSwapCalldata } from '../utils.js'
import HookABI from '../../abis/PermissionedCSMMHook.json' assert { type: 'json' }
import UniversalRouterABI from '../../abis/UniversalRouter.json' assert { type: 'json' }

const USDC_DECIMALS = 6
const SWAP_AMOUNT   = 10_000n * 10n ** BigInt(USDC_DECIMALS) // 10,000 USDC

const FEE_BPS: Record<number, string> = { 0: '3 bps (Bronze)', 1: '1 bps (Silver)', 2: '0 bps (Gold)' }

export async function executeSwap(tier: TierKey) {
  const inst   = getInstitution(tier)
  const client = getInstitutionClient(tier)
  step(6, `Executing institutional swap — 10,000 USDC -> USDT0 (${inst.tierName} tier, ${FEE_BPS[inst.tier]})`)

  const [usdcBefore, usdt0Before] = await readBalances(inst.address)
  stateTable('Balances before swap', [
    ['USDC',  formatUnits(usdcBefore, USDC_DECIMALS) + ' USDC'],
    ['USDT0', formatUnits(usdt0Before, USDC_DECIMALS) + ' USDT0'],
  ])

  // Approve router to spend USDC
  await approveToken(client, CONTRACTS.unichain.usdc, CONTRACTS.unichain.router, SWAP_AMOUNT)
  info('USDC approved for Universal Router')

  // hookData encodes the institution address for beforeSwap allowlist check
  const hookData = encodeAbiParameters(
    parseAbiParameters('address'),
    [inst.address]
  )

  const [commands, inputs, deadline] = buildSwapCalldata(SWAP_AMOUNT, hookData)
  const hash = await client.writeContract({
    address: CONTRACTS.unichain.router,
    abi: UniversalRouterABI as Abi,
    functionName: 'execute',
    args: [commands, inputs, deadline],
  })
  txLink('Swap tx (Unichain Sepolia)', hash, 'unichain')
  await unichainPublic.waitForTransactionReceipt({ hash })

  const [usdcAfter, usdt0After] = await readBalances(inst.address)
  const received   = usdt0After - usdt0Before
  const feeCharged = SWAP_AMOUNT - received
  const lpShare    = feeCharged / 2n
  const opShare    = feeCharged - lpShare

  // Read updated operator accrued fees from hook
  const accruedFees = await unichainPublic.readContract({
    address: CONTRACTS.unichain.hook,
    abi: HookABI as Abi,
    functionName: 'accruedFees',
    args: [CONTRACTS.unichain.usdt0],
  }) as bigint

  stateTable('Balances after swap', [
    ['USDC spent',       formatUnits(SWAP_AMOUNT, USDC_DECIMALS) + ' USDC'],
    ['USDT0 received',   formatUnits(received, USDC_DECIMALS) + ' USDT0'],
    ['Fee charged',      formatUnits(feeCharged, USDC_DECIMALS) + ` USDT0 (${FEE_BPS[inst.tier]})`],
    ['LP share (50%)',   formatUnits(lpShare, USDC_DECIMALS) + ' USDT0 (donated to pool)'],
    ['Operator share',   formatUnits(opShare, USDC_DECIMALS) + ' USDT0 (accrued in hook)'],
    ['Total accrued',    formatUnits(accruedFees, USDC_DECIMALS) + ' USDT0'],
  ])

  success(`CSMM 1:1 swap executed with ${inst.tierName} tier fee split correctly`)
}
