import { encodeAbiParameters, formatUnits, parseAbiParameters, maxUint160, maxUint48, type Abi } from 'viem'
import { getInstitutionClient, unichainPublic } from '../clients.js'
import { CONTRACTS, type TierKey, getInstitution } from '../config.js'
import { step, info, success, txLink, stateTable } from '../logger.js'
import { approveToken, readBalances, buildSwapCalldata } from '../utils.js'
import HookABI from '../../abis/PermissionedCSMMHook.json' assert { type: 'json' }

const USDC_DECIMALS = 6
const SWAP_AMOUNT   = 10_000n * 10n ** BigInt(USDC_DECIMALS) // 10,000 USDC

const FEE_BPS: Record<number, string> = { 0: '3 bps (Bronze)', 1: '1 bps (Silver)', 2: '0 bps (Gold)' }

// Canonical Permit2 address (same on all chains)
const PERMIT2 = '0x000000000022D473030F116dDEE9F6B43aC78BA3' as `0x${string}`

const PERMIT2_ABI = [
  {
    type: 'function',
    name: 'approve',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint160' },
      { name: 'expiration', type: 'uint48' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const

// Universal Router ABI — uses the 3-arg execute(bytes commands, bytes[] inputs, uint256 deadline)
const UNIVERSAL_ROUTER_ABI = [
  {
    type: 'function',
    name: 'execute',
    inputs: [
      { name: 'commands', type: 'bytes' },
      { name: 'inputs', type: 'bytes[]' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [],
    stateMutability: 'payable',
  },
] as const

export async function executeSwap(tier: TierKey) {
  const inst   = getInstitution(tier)
  const client = getInstitutionClient(tier)
  step(6, `Executing institutional swap — 10,000 USDC -> USDT0 (${inst.tierName} tier, ${FEE_BPS[inst.tier]})`)

  const [usdcBefore, usdt0Before] = await readBalances(inst.address)
  stateTable('Balances before swap', [
    ['USDC',  formatUnits(usdcBefore, USDC_DECIMALS) + ' USDC'],
    ['USDT0', formatUnits(usdt0Before, USDC_DECIMALS) + ' USDT0'],
  ])

  // Step 1: ERC20 approve Permit2 to spend USDC
  await approveToken(client, CONTRACTS.unichain.usdc, PERMIT2, SWAP_AMOUNT * 2n)
  info('ERC20 approval granted to Permit2')

  // Step 2: Permit2 approve Universal Router to spend via Permit2
  const approveHash = await client.writeContract({
    address: PERMIT2,
    abi: PERMIT2_ABI,
    functionName: 'approve',
    args: [CONTRACTS.unichain.usdc, CONTRACTS.unichain.router, maxUint160, Number(maxUint48)],
  })
  await unichainPublic.waitForTransactionReceipt({ hash: approveHash })
  info('Permit2 allowance granted to Universal Router')

  // hookData encodes the institution address for beforeSwap allowlist check
  const hookData = encodeAbiParameters(
    parseAbiParameters('address'),
    [inst.address]
  )

  // Build v4 swap actions via SDK — SWAP_EXACT_IN_SINGLE + SETTLE + TAKE
  const v4ActionsData = buildSwapCalldata(SWAP_AMOUNT, hookData)

  // Universal Router command 0x10 = V4_SWAP — wraps v4 actions/params as a single input
  const commands = '0x10' as `0x${string}`
  const inputs: `0x${string}`[] = [v4ActionsData]
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800) // 30 min

  // Universal Router's execute(bytes commands, bytes[] inputs, uint256 deadline)
  const hash = await client.writeContract({
    address: CONTRACTS.unichain.router,
    abi: UNIVERSAL_ROUTER_ABI,
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
