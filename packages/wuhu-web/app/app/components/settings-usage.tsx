import { useEffect, useState } from 'react'
import { Pill } from '@wuhu/ui'
import type { ProviderDescriptor } from '~/lib/contract.gen'
import { relativeSpan } from '~/lib/relative-time'
import {
  type UsageCard as Card,
  usageCards,
  usageTone,
  type UsageWindowRow,
} from '~/lib/usage'
import { errorMessage } from '~/sdk/errors'
import { fetchProviders } from '~/sdk/providers'

export function UsageCard() {
  const [providers, setProviders] = useState<ProviderDescriptor[] | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [now, setNow] = useState(() => new Date())

  useEffect(() => {
    let cancelled = false
    const load = () =>
      fetchProviders().then(
        (found) => {
          if (cancelled) return
          setProviders(found)
          setFailure(null)
          setNow(new Date())
        },
        (failed: unknown) => {
          if (cancelled) return
          setFailure(errorMessage(failed))
          setNow(new Date())
        },
      )
    void load()
    const tick = setInterval(load, 60_000)
    return () => {
      cancelled = true
      clearInterval(tick)
    }
  }, [])

  const cards = providers == null ? [] : usageCards(providers, now)
  return (
    <section className='wuhu-card wuhu-settings-card'>
      <p className='wuhu-eyebrow'>Plan usage</p>
      <p className='wuhu-muted'>
        What each provider's plan has left, refreshed every minute
      </p>
      {failure
        ? <p className='wuhu-alert'>{failure}</p>
        : cards.length === 0 && (
          <p className='wuhu-muted'>
            {providers == null
              ? 'Loading…'
              : 'No provider here reports plan usage.'}
          </p>
        )}
      {cards.map((card) => (
        <UsageCell key={card.provider} card={card} now={now} />
      ))}
    </section>
  )
}

function UsageCell({ card, now }: { card: Card; now: Date }) {
  return (
    <div className='wuhu-usage' data-state={card.kind}>
      <div className='wuhu-usage-head'>
        <strong>{card.provider}</strong>
        {card.kind !== 'unobserved' && card.plan && <Pill>{card.plan}</Pill>}
        {card.kind === 'stale' && <Pill tone='amber'>stale</Pill>}
      </div>
      {card.kind === 'unobserved'
        ? <p className='wuhu-usage-note'>Not observed yet</p>
        : (
          <>
            {card.windows.map((window) => (
              <WindowBar key={window.name} window={window} now={now} />
            ))}
            <p className='wuhu-usage-note'>
              as of {relativeSpan(card.observedAt, now)}
            </p>
          </>
        )}
    </div>
  )
}

function WindowBar({ window, now }: { window: UsageWindowRow; now: Date }) {
  const { meter, resetsAt } = window
  const used = meter.kind === 'used' ? meter.percent : null
  return (
    <div className='wuhu-usage-window'>
      <span className='wuhu-usage-name'>{window.name}</span>
      <span className='wuhu-usage-track'>
        {used != null && (
          <span
            className='wuhu-usage-fill'
            data-tone={usageTone(used)}
            style={{ width: `${Math.min(Math.max(used, 0), 100)}%` }}
          />
        )}
      </span>
      <span className='wuhu-usage-percent'>
        {used == null ? '—' : `${Math.round(used)}%`}
      </span>
      {resetsAt && (
        <span className='wuhu-usage-reset'>
          {meter.kind === 'reset' ? 'reset' : 'resets'}{' '}
          {relativeSpan(resetsAt, now)}
        </span>
      )}
    </div>
  )
}
