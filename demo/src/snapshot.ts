import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { info, warn } from './logger.js'
import type { TierKey } from './config.js'

const SNAPSHOT_FILE = 'demo-snapshot.json'

interface Snapshot {
  tier: TierKey
  lastCompletedStep: number
  timestamp: string
}

export function loadSnapshot(tier: TierKey): number {
  if (!existsSync(SNAPSHOT_FILE)) return 0

  try {
    const data: Snapshot = JSON.parse(readFileSync(SNAPSHOT_FILE, 'utf-8'))

    // Only resume if same tier — different tier means start fresh
    if (data.tier !== tier) {
      warn(`Snapshot is for ${data.tier} tier, but running ${tier} — starting fresh`)
      return 0
    }

    if (data.lastCompletedStep > 0) {
      info(`Resuming from snapshot: step ${data.lastCompletedStep} completed at ${data.timestamp}`)
      info(`Skipping steps 1-${data.lastCompletedStep}, starting at step ${data.lastCompletedStep + 1}`)
    }

    return data.lastCompletedStep
  } catch {
    return 0
  }
}

export function saveSnapshot(tier: TierKey, stepNumber: number): void {
  const snapshot: Snapshot = {
    tier,
    lastCompletedStep: stepNumber,
    timestamp: new Date().toISOString(),
  }
  writeFileSync(SNAPSHOT_FILE, JSON.stringify(snapshot, null, 2) + '\n')
}

export function clearSnapshot(): void {
  if (existsSync(SNAPSHOT_FILE)) {
    writeFileSync(SNAPSHOT_FILE, JSON.stringify({ tier: '', lastCompletedStep: 0, timestamp: '' }, null, 2) + '\n')
  }
}
