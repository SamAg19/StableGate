import { encodeAbiParameters, formatUnits, parseAbiParameters, maxUint160, maxUint48 } from 'viem'
import { unichainLP, unichainPublic } from '../clients.js'
import { CONTRACTS, LP_INSTITUTION } from '../config.js'
import { step, info, success, txLink, stateTable } from '../logger.js'
import { approveToken, readReserves, buildAddLiquidityCalldata } from '../utils.js'

const LP_AMOUNT = 50_000n * 10n ** 6n // 50,000 each token

// Canonical Permit2 address (same on all chains)
const PERMIT2 = '0x000000000022D473030F116dDEE9F6B43aC78BA3' as `0x${string}`

// Permit2 approve ABI
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

export async function addLiquidity() {
  const lpAddr = LP_INSTITUTION.address
  step(3, 'Adding liquidity to StableGate pool (LP institution) — Unichain Sepolia')

  const [r0Before, r1Before] = await readReserves()
  stateTable('Pool reserves before', [
    ['USDC reserve',     formatUnits(r0Before, 6) + ' USDC'],
    ['USDT0 reserve',    formatUnits(r1Before, 6) + ' USDT0'],
    ['LP whitelisted',   'true'],
    ['LP Institution',   lpAddr],
  ])

  // Step 1: ERC20 approve Permit2 (max approval)
  const MAX_APPROVE = 2n ** 256n - 1n
  await approveToken(unichainLP, CONTRACTS.unichain.usdc,  PERMIT2, MAX_APPROVE)
  await approveToken(unichainLP, CONTRACTS.unichain.usdt0, PERMIT2, MAX_APPROVE)
  info('ERC20 approvals granted to Permit2')

  // Step 2: Permit2 approve PositionManager
  const positionManager = CONTRACTS.unichain.positionManager
  for (const token of [CONTRACTS.unichain.usdc, CONTRACTS.unichain.usdt0]) {
    const hash = await unichainLP.writeContract({
      address: PERMIT2,
      abi: PERMIT2_ABI,
      functionName: 'approve',
      args: [token, positionManager, maxUint160, Number(maxUint48)],
    })
    await unichainPublic.waitForTransactionReceipt({ hash })
  }
  info('Permit2 allowances granted to Position Manager')

  // hookData encodes LP address for beforeAddLiquidity whitelist check
  const hookData = encodeAbiParameters(
    parseAbiParameters('address'),
    [lpAddr]
  )

  // Build calldata via Uniswap v4 SDK
  const { calldata, value } = buildAddLiquidityCalldata(LP_AMOUNT, hookData, lpAddr)

  const hash = await unichainLP.sendTransaction({
    to: positionManager,
    data: calldata as `0x${string}`,
    value: BigInt(value),
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

  success('Liquidity added — LP institution is now an active LP earning swap fees')
}
