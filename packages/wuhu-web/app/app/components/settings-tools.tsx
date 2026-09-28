import { useEffect, useState } from 'react'
import { Icon } from '@wuhu/ui'
import type {
  SessionToolExecutor,
  ToolDescriptor,
  ToolRosterDescriptor,
} from '~/lib/contract.gen'
import {
  executors,
  matchingTools,
  rosterSummary,
  rosterTools,
} from '~/lib/tool-roster'
import { errorMessage } from '~/sdk/errors'
import { fetchToolRosters } from '~/sdk/session-tools'

export function ToolsCard() {
  const [rosters, setRosters] = useState<ToolRosterDescriptor[] | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [reloads, setReloads] = useState(0)
  const [executor, setExecutor] = useState<SessionToolExecutor>('kernel')
  const [query, setQuery] = useState('')
  const [openTool, setOpenTool] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    fetchToolRosters().then(
      (found) => {
        if (cancelled) return
        setRosters(found)
        setFailure(null)
      },
      (failed: unknown) => {
        if (!cancelled) setFailure(errorMessage(failed))
      },
    )
    return () => {
      cancelled = true
    }
  }, [reloads])

  const roster = rosters == null ? [] : rosterTools(rosters, executor)
  const shown = matchingTools(roster, query)
  return (
    <section className='wuhu-card wuhu-settings-card'>
      <p className='wuhu-eyebrow'>Tools</p>
      <p className='wuhu-muted'>
        The roster a session of each executor is handed
      </p>
      <div className='wuhu-tools-bar'>
        <div className='wuhu-tabs wuhu-settings-tabs' role='tablist'>
          {executors.map((option) => (
            <button
              key={option.executor}
              type='button'
              role='tab'
              aria-selected={executor === option.executor}
              className={executor === option.executor ? 'active' : undefined}
              onClick={() => {
                setExecutor(option.executor)
                setOpenTool(null)
              }}
            >
              {option.label}
            </button>
          ))}
        </div>
        <button
          type='button'
          className='wui-icon-button'
          aria-label='Reload'
          title='Reload'
          onClick={() => setReloads((n) => n + 1)}
        >
          <Icon name='restart' />
        </button>
      </div>
      <label className='wuhu-field wuhu-field-wide'>
        <input
          aria-label='Filter tools'
          placeholder='Filter by name or description'
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
      </label>
      <p className={failure ? 'wuhu-alert' : 'wuhu-usage-note'}>
        {failure ??
          (rosters == null ? 'Loading…' : rosterSummary(rosters, executor))}
      </p>
      {rosters != null && failure == null && shown.length === 0 && (
        <p className='wuhu-muted'>
          {roster.length === 0
            ? 'This executor is handed no tools.'
            : 'Nothing matches that.'}
        </p>
      )}
      {shown.map((tool) => (
        <ToolRow
          key={tool.name}
          tool={tool}
          open={openTool === tool.name}
          onToggle={() =>
            setOpenTool(openTool === tool.name ? null : tool.name)}
        />
      ))}
    </section>
  )
}

function ToolRow({ tool, open, onToggle }: {
  tool: ToolDescriptor
  open: boolean
  onToggle: () => void
}) {
  return (
    <div className='wuhu-tool'>
      <button type='button' aria-expanded={open} onClick={onToggle}>
        <span className='wuhu-tool-name'>
          <code>{tool.name}</code>
          <Icon name={open ? 'chevronDown' : 'chevronRight'} />
        </span>
        <span className='wuhu-tool-description' data-open={open}>
          {open ? tool.description : tool.description.split('\n')[0]}
        </span>
      </button>
      {open && (
        <pre className='wuhu-tool-schema'>
          {JSON.stringify(tool.parameters, null, 2)}
        </pre>
      )}
    </div>
  )
}
