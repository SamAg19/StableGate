import { createPublicClient, createWalletClient, http, type WalletClient, type Transport, type Chain, type Account } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'
import { unichainSepolia, reactiveLasna, INSTITUTIONS, type TierKey } from './config.js'

function requireKey(key: string): `0x${string}` {
  const val = process.env[key]
  if (!val) throw new Error(`Missing env var: ${key}`)
  return val as `0x${string}`
}

const operatorAccount = privateKeyToAccount(requireKey('OPERATOR_PRIVATE_KEY'))

// ── Public clients — read-only ─────────────────────────────────────────────

export const basePublic     = createPublicClient({ chain: baseSepolia,     transport: http() })
export const unichainPublic = createPublicClient({ chain: unichainSepolia, transport: http() })
export const reactivePublic = createPublicClient({ chain: reactiveLasna,   transport: http() })
// reactivePublic is only used to fetch the current block number for
// Reactscan link generation — no transactions sent to Reactive Lasna

// ── Wallet clients — write ─────────────────────────────────────────────────

export const baseOperator     = createWalletClient({ account: operatorAccount, chain: baseSepolia,     transport: http() })
export const unichainOperator = createWalletClient({ account: operatorAccount, chain: unichainSepolia, transport: http() })

// Institution wallet clients — one per tier
const institutionClients: Record<TierKey, WalletClient<Transport, Chain, Account>> = {
  bronze: createWalletClient({
    account: privateKeyToAccount(INSTITUTIONS.bronze.privateKey),
    chain: unichainSepolia,
    transport: http(),
  }),
  silver: createWalletClient({
    account: privateKeyToAccount(INSTITUTIONS.silver.privateKey),
    chain: unichainSepolia,
    transport: http(),
  }),
  gold: createWalletClient({
    account: privateKeyToAccount(INSTITUTIONS.gold.privateKey),
    chain: unichainSepolia,
    transport: http(),
  }),
}

export function getInstitutionClient(tier: TierKey) {
  return institutionClients[tier]
}
