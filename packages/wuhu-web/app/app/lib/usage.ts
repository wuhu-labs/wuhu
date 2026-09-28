import type { ProviderDescriptor } from './contract.gen.ts'

// The server re-reads each plan every 15 minutes; two missed reads in a row
// mean the figures on screen no longer describe the plan.
export const usageStaleAfterMs = 30 * 60 * 1000

export type UsageMeter =
  | { kind: 'used'; percent: number }
  | { kind: 'unreported' }
  | { kind: 'reset' }

export interface UsageWindowRow {
  name: string
  meter: UsageMeter
  resetsAt: Date | null
}

export type UsageCard =
  | { provider: string; kind: 'unobserved' }
  | {
    provider: string
    kind: 'observed' | 'stale'
    plan: string | null
    observedAt: Date
    windows: UsageWindowRow[]
  }

const planDialects = new Set(['codex', 'claude'])

export function usageCards(
  providers: ProviderDescriptor[],
  now: Date,
): UsageCard[] {
  return providers.flatMap((provider): UsageCard[] => {
    const usage = provider.usage
    if (usage == null) {
      return planDialects.has(provider.dialect)
        ? [{ provider: provider.id, kind: 'unobserved' }]
        : []
    }
    const observedAt = new Date(usage.observedAt * 1000)
    return [{
      provider: provider.id,
      kind: now.getTime() - observedAt.getTime() > usageStaleAfterMs
        ? 'stale'
        : 'observed',
      plan: usage.plan ?? null,
      observedAt,
      windows: usage.windows.map((window) => {
        const resetsAt = window.resetsAt == null
          ? null
          : new Date(window.resetsAt * 1000)
        return {
          name: window.name.replaceAll('_', ' '),
          meter: resetsAt != null && resetsAt <= now
            ? { kind: 'reset' }
            : window.usedPercent == null
            ? { kind: 'unreported' }
            : { kind: 'used', percent: window.usedPercent },
          resetsAt,
        }
      }),
    }]
  })
}

export function usageTone(percent: number): 'rose' | 'amber' | 'mint' {
  if (percent >= 90) return 'rose'
  if (percent >= 60) return 'amber'
  return 'mint'
}
