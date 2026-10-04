import type { ReactNode } from 'react'
import { Pill } from '@wuhu/ui'
import { TurnTimeline } from '~/components/turn-timeline'
import { directStates } from '~/lib/fixtures'
import { sharedGroup } from '~/lib/groups'
import { projectTurns } from '~/lib/turns'
import { workEvents } from '~/lib/work-events'

export function meta() {
  return [{ title: 'Gallery · Wuhu (dev)' }]
}

function Panel({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className='wuhu-card'>
      <p className='wuhu-eyebrow'>{label}</p>
      {children}
    </div>
  )
}

export default function Gallery() {
  return (
    <div className='wuhu-content wuhu-standalone wuhu-page'>
      <p className='wuhu-eyebrow'>Dev only</p>
      <h1 className='wuhu-title'>Component gallery</h1>
      <p className='wuhu-muted' style={{ margin: '0.8rem 0 2rem' }}>
        Fixtures for design review; states share the fold test fixtures. Capture
        in light and dark to review both schemes.
      </p>

      <h2>Liveness</h2>
      <Panel label='reconnecting'>
        <Pill tone='amber' dot>reconnecting</Pill>
      </Panel>

      <h2 style={{ marginTop: '2rem' }}>Turns</h2>
      <div style={{ display: 'grid', gap: '1rem' }}>
        {Object.entries(directStates).map(([name, state]) => (
          <Panel key={name} label={name}>
            <TurnTimeline
              projection={projectTurns(workEvents(state), false)}
              status={null}
              group={sharedGroup}
              names={{
                session: () =>
                  undefined,
                principal: (id) =>
                  id,
              }}
              inspect={() => {}}
            />
          </Panel>
        ))}
      </div>
    </div>
  )
}
