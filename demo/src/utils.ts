import 'dotenv/config'
import { type Abi, type WalletClient, type Transport, type Chain, type Account } from 'viem'
import { Token, Percent, CurrencyAmount } from '@uniswap/sdk-core'
import { Pool, Position, V4PositionManager, V4Planner, Actions } from '@uniswap/v4-sdk'
import JSBI from 'jsbi'
import { unichainPublic, basePublic } from './clients.js'
import { CONTRACTS, PROTOCOL } from './config.js'
import MembershipNFTABI from '../abis/MembershipNFT.json' assert { type: 'json' }
import LPMembershipNFTABI from '../abis/LPMembershipNFT.json' assert { type: 'json' }

// ── Token definitions ──────────────────────────────────────────────────────

const UNICHAIN_CHAIN_ID = PROTOCOL.chainIds.unichainSepolia

function getTokens(): [Token, Token] {
  const usdc  = new Token(UNICHAIN_CHAIN_ID, CONTRACTS.unichain.usdc,  6, 'USDC',  'USD Coin (Mock)')
  const usdt0 = new Token(UNICHAIN_CHAIN_ID, CONTRACTS.unichain.usdt0, 6, 'USDT0', 'Tether USD0 (Mock)')
  // SDK sorts internally — but we track which is which
  return usdc.sortsBefore(usdt0) ? [usdc, usdt0] : [usdt0, usdc]
}

// ── ERC20 helpers ──────────────────────────────────────────────────────────

export const ERC20_ABI = [
  {
    name: 'approve',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const satisfies Abi

export async function approveToken(
  client: WalletClient<Transport, Chain, Account>,
  token: `0x${string}`,
  spender: `0x${string}`,
  amount: bigint
): Promise<void> {
  const hash = await client.writeContract({
    address: token,
    abi: ERC20_ABI,
    functionName: 'approve',
    args: [spender, amount],
  })
  await unichainPublic.waitForTransactionReceipt({ hash })
}

export async function readBalances(account: `0x${string}`): Promise<[bigint, bigint]> {
  const [usdc, usdt0] = await Promise.all([
    unichainPublic.readContract({
      address: CONTRACTS.unichain.usdc,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [account],
    }),
    unichainPublic.readContract({
      address: CONTRACTS.unichain.usdt0,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [account],
    }),
  ])
  return [usdc, usdt0]
}

// ── Pool reserves (PoolManager token balances) ──────────────────────────────

const POOL_MANAGER = '0x00B036B58a818B1BC34d502D3fE730Db729e62AC' as `0x${string}`

export async function readReserves(): Promise<[bigint, bigint]> {
  const [r0, r1] = await Promise.all([
    unichainPublic.readContract({
      address: CONTRACTS.unichain.usdc,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [POOL_MANAGER],
    }),
    unichainPublic.readContract({
      address: CONTRACTS.unichain.usdt0,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [POOL_MANAGER],
    }),
  ])
  return [r0, r1]
}

// ── Token ID helpers ───────────────────────────────────────────────────────

export async function getTokenId(_institution: `0x${string}`): Promise<bigint> {
  const nextId = await basePublic.readContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'nextTokenId',
    args: [],
  }) as bigint
  return nextId - 1n
}

export async function getLPTokenId(_institution: `0x${string}`): Promise<bigint> {
  const nextId = await basePublic.readContract({
    address: CONTRACTS.base.lpMembershipNFT,
    abi: LPMembershipNFTABI as Abi,
    functionName: 'nextTokenId',
    args: [],
  }) as bigint
  return nextId - 1n
}

// ── Pool helper ────────────────────────────────────────────────────────────

function createPool(): Pool {
  const [token0, token1] = getTokens()
  // CSMM pool at 1:1 price — sqrtPriceX96 for 1:1 with equal decimals
  const SQRT_PRICE_1_1 = JSBI.BigInt('79228162514264337593543950336')
  return new Pool(
    token0,
    token1,
    100,                          // fee: 0.01% (matches DeployUnichain)
    1,                            // tickSpacing: 1 (matches DeployUnichain)
    CONTRACTS.unichain.hook,      // hooks address
    SQRT_PRICE_1_1,               // sqrtRatioX96 at 1:1
    JSBI.BigInt(0),               // liquidity (not needed for encoding)
    0,                            // tickCurrent (tick 0 at 1:1)
    []                            // no tick data needed
  )
}

// ── Add liquidity calldata (via Uniswap v4 SDK) ───────────────────────────
// Uses V4PositionManager.addCallParameters() which correctly encodes:
//   MINT_POSITION + CLOSE_CURRENCY + CLOSE_CURRENCY
// hookData encodes the LP address for beforeAddLiquidity whitelist check.

export function buildAddLiquidityCalldata(
  amount: bigint,
  hookData: `0x${string}`,
  owner: `0x${string}`
): { calldata: `0x${string}`; value: bigint } {
  const pool = createPool()

  // Create position from desired token amounts
  const position = Position.fromAmounts({
    pool,
    tickLower: -887272,   // full range
    tickUpper: 887272,    // full range
    amount0: amount.toString(),
    amount1: amount.toString(),
    useFullPrecision: true,
  })

  const mintOptions = {
    recipient: owner,
    slippageTolerance: new Percent(50, 100), // 50% slippage tolerance (testnet)
    deadline: Math.floor(Date.now() / 1000) + 1800, // 30 min
    hookData,
  }

  const { calldata, value } = V4PositionManager.addCallParameters(position, mintOptions)

  return {
    calldata: calldata as `0x${string}`,
    value: BigInt(value),
  }
}

// ── Swap calldata (via Uniswap v4 SDK V4Planner) ────────────────────────────
// Uses V4Planner to encode:
//   SWAP_EXACT_IN_SINGLE + SETTLE (payer=true) + TAKE (to MSG_SENDER)
// hookData encodes the institution address for beforeSwap allowlist check.
//
// V4Planner.addAction expects raw JS values — ethers v5 encodes them internally.
// The struct format for SWAP_EXACT_IN_SINGLE is:
//   (PoolKey poolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, bytes hookData)

export function buildSwapCalldata(
  amount: bigint,
  hookData: `0x${string}`
): `0x${string}` {
  const [token0, token1] = getTokens()
  const pool = createPool()

  // Determine swap direction — USDC → USDT0
  const usdcIsToken0 = token0.address.toLowerCase() === CONTRACTS.unichain.usdc.toLowerCase()
  const zeroForOne = usdcIsToken0

  const planner = new V4Planner()

  // SWAP_EXACT_IN_SINGLE: single struct param as nested array
  // Struct: (PoolKey poolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, bytes hookData)
  const swapStruct = [
    [token0.address, token1.address, pool.fee, pool.tickSpacing, pool.hooks], // PoolKey tuple
    zeroForOne,
    amount.toString(),   // amountIn
    '0',                 // amountOutMinimum (0 for testnet)
    hookData,
  ]
  planner.addAction(Actions.SWAP_EXACT_IN_SINGLE, [swapStruct])

  // SETTLE: pay input token from caller
  const inputCurrency = zeroForOne ? token0 : token1
  planner.addSettle(inputCurrency, true)

  // TAKE: receive output token to caller
  // MSG_SENDER = address(1) in ActionConstants — tells router to send to msg.sender
  const outputCurrency = zeroForOne ? token1 : token0
  planner.addTake(outputCurrency, '0x0000000000000000000000000000000000000001')

  // finalize() returns ABI-encoded string: abi.encode(bytes actions, bytes[] params)
  return planner.finalize() as `0x${string}`
}
