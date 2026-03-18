import { encodeAbiParameters, parseAbiParameters, type Abi } from 'viem'
import { unichainInstitution, unichainPublic, basePublic } from './clients.js'
import { CONTRACTS, INSTITUTION_ADDRESS } from './config.js'
import MembershipNFTABI from '../abis/MembershipNFT.json' assert { type: 'json' }
import LPMembershipNFTABI from '../abis/LPMembershipNFT.json' assert { type: 'json' }

// ── ERC20 helpers ──────────────────────────────────────────────────────────

const ERC20_ABI = [
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
  token: `0x${string}`,
  spender: `0x${string}`,
  amount: bigint
): Promise<void> {
  const hash = await unichainInstitution.writeContract({
    address: token,
    abi: ERC20_ABI,
    functionName: 'approve',
    args: [spender, amount],
  })
  await unichainPublic.waitForTransactionReceipt({ hash })
}

export async function readBalances(): Promise<[bigint, bigint]> {
  const [usdc, usdt0] = await Promise.all([
    unichainPublic.readContract({
      address: CONTRACTS.unichain.usdc,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [INSTITUTION_ADDRESS],
    }),
    unichainPublic.readContract({
      address: CONTRACTS.unichain.usdt0,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [INSTITUTION_ADDRESS],
    }),
  ])
  return [usdc, usdt0]
}

// ── Pool reserves (PoolManager token balances) ──────────────────────────────

const POOL_MANAGER = '0x1F98400000000000000000000000000000000004' as `0x${string}`

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

export async function getTokenId(institution: `0x${string}`): Promise<bigint> {
  // The most recently minted token ID is nextTokenId - 1
  const nextId = await basePublic.readContract({
    address: CONTRACTS.base.membershipNFT,
    abi: MembershipNFTABI as Abi,
    functionName: 'nextTokenId',
    args: [],
  }) as bigint
  return nextId - 1n
}

export async function getLPTokenId(institution: `0x${string}`): Promise<bigint> {
  const nextId = await basePublic.readContract({
    address: CONTRACTS.base.lpMembershipNFT,
    abi: LPMembershipNFTABI as Abi,
    functionName: 'nextTokenId',
    args: [],
  }) as bigint
  return nextId - 1n
}

// ── Swap calldata builder ──────────────────────────────────────────────────
// Builds the calldata for a USDC → USDT0 swap through the Universal Router.
// The exact encoding depends on the Universal Router version deployed on
// Unichain Sepolia. This is a placeholder — populate with the correct
// command encoding after verifying the deployed router version.
//
// hookData encodes the institution address for the beforeSwap allowlist check.

export function buildSwapCalldata(
  amount: bigint,
  hookData: `0x${string}`
): [`0x${string}`, `0x${string}`[], bigint] {
  // Universal Router V4_SWAP command (0x10)
  // The inputs encode: PoolKey, SwapParams, hookData
  // This is a simplified placeholder — the actual encoding requires
  // the specific command structure for the deployed router version.
  const commands = '0x10' as `0x${string}`
  const inputs: `0x${string}`[] = [
    encodeAbiParameters(
      parseAbiParameters('address, bool, int256, uint160, bytes'),
      [
        CONTRACTS.unichain.hook,  // pool with this hook
        true,                     // zeroForOne (USDC → USDT0, assuming USDC < USDT0)
        -BigInt(amount),          // exact input (negative = exact input in v4)
        BigInt(0) as unknown as bigint,  // sqrtPriceLimitX96 (0 = no limit)
        hookData,
      ]
    ),
  ]
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800) // 30 min deadline
  return [commands, inputs, deadline]
}

// ── Add liquidity calldata builder ─────────────────────────────────────────
// Builds calldata for adding liquidity via the Position Manager.
// hookData encodes the LP address for beforeAddLiquidity whitelist check.
//
// This is a placeholder — the actual encoding depends on the deployed
// PositionManager version on Unichain Sepolia.

export function buildAddLiquidityCalldata(
  amount: bigint,
  hookData: `0x${string}`
): `0x${string}` {
  // PositionManager.modifyLiquidities() encoding
  // The exact format depends on the deployed version.
  // This placeholder returns the hookData-wrapped encoding.
  return encodeAbiParameters(
    parseAbiParameters('uint256, int24, int24, int256, bytes'),
    [
      0n,       // tokenId (0 = new position)
      -887272,  // tickLower (full range)
      887272,   // tickUpper (full range)
      BigInt(amount),  // liquidityDelta
      hookData,
    ]
  )
}
