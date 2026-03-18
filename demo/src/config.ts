import 'dotenv/config'
import { defineChain } from 'viem'

// ── Chain definitions ──────────────────────────────────────────────────────

export const unichainSepolia = defineChain({
  id: 1301,
  name: 'Unichain Sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.UNICHAIN_SEPOLIA_RPC ?? 'https://sepolia.unichain.org'] }
  },
  blockExplorers: {
    default: { name: 'Uniscan', url: 'https://sepolia.uniscan.xyz' }
  }
})

export const reactiveLasna = defineChain({
  id: 5318007,
  name: 'Reactive Lasna',
  nativeCurrency: { name: 'REACT', symbol: 'REACT', decimals: 18 },
  rpcUrls: {
    default: { http: ['https://lasna-rpc.rnk.dev/'] }
  },
  blockExplorers: {
    default: { name: 'Reactscan', url: 'https://reactscan.net' }
  }
})

// ── Protocol constants — verified from Reactive Network docs ───────────────

export const PROTOCOL = {
  // Callback proxy addresses — fixed per chain, NOT operator-configurable
  callbackProxy: {
    unichainSepolia: '0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4' as `0x${string}`,
    baseSepolia:     '0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6' as `0x${string}`,
    reactiveLasna:   '0x0000000000000000000000000000000000fffFfF' as `0x${string}`,
  },
  // Chain IDs
  chainIds: {
    baseSepolia:     84532,
    unichainSepolia: 1301,
    reactiveLasna:   5318007,
  }
} as const

// ── Contract addresses — from .env ─────────────────────────────────────────

function requireEnv(key: string): `0x${string}` {
  const val = process.env[key]
  if (!val) throw new Error(`Missing required env var: ${key}`)
  return val as `0x${string}`
}

export const CONTRACTS = {
  base: {
    membershipNFT:   requireEnv('MEMBERSHIP_NFT'),
    lpMembershipNFT: requireEnv('LP_MEMBERSHIP_NFT'),
  },
  unichain: {
    hook:            requireEnv('HOOK_CONTRACT'),
    usdc:            requireEnv('USDC_ADDRESS'),
    usdt0:           requireEnv('USDT0_ADDRESS'),
    router:          requireEnv('UNIVERSAL_ROUTER'),
    positionManager: requireEnv('POSITION_MANAGER'),
  },
  reactive: {
    allowlistRSC: requireEnv('ALLOWLIST_REACTIVE_CONTRACT'),
  }
} as const

export const OPERATOR_ADDRESS = requireEnv('OPERATOR_ADDRESS')

// Three institutions — one per tier
export const INSTITUTIONS = {
  bronze: {
    address: requireEnv('INSTITUTION_BRONZE_ADDRESS'),
    privateKey: requireEnv('INSTITUTION_BRONZE_PRIVATE_KEY'),
    tier: 0 as const,
    tierName: 'Bronze' as const,
  },
  silver: {
    address: requireEnv('INSTITUTION_SILVER_ADDRESS'),
    privateKey: requireEnv('INSTITUTION_SILVER_PRIVATE_KEY'),
    tier: 1 as const,
    tierName: 'Silver' as const,
  },
  gold: {
    address: requireEnv('INSTITUTION_GOLD_ADDRESS'),
    privateKey: requireEnv('INSTITUTION_GOLD_PRIVATE_KEY'),
    tier: 2 as const,
    tierName: 'Gold' as const,
  },
} as const

export type TierKey = keyof typeof INSTITUTIONS

// Default institution used when --tier is not specified
export const DEFAULT_TIER: TierKey = 'silver'

export function getInstitution(tier?: TierKey) {
  return INSTITUTIONS[tier ?? DEFAULT_TIER]
}

// ── Reactscan helpers ──────────────────────────────────────────────────────

export function reactscanRscUrl(contractAddress: string): string {
  return `https://reactscan.net/rsc/${contractAddress}`
}

export function reactscanTxUrl(txHash: string): string {
  return `https://reactscan.net/tx/${txHash}`
}
