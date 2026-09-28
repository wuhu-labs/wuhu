import {
  Icon,
  type IconName,
  SidebarNote,
  SidebarRow,
  SidebarSection,
} from '@wuhu/ui'
import type { QueryOutput } from '~/lib/contract.gen'
import { initialsFrom } from '~/lib/directory'
import { flatten, nest } from '~/lib/outline'
import type { SessionRecord } from '~/lib/session-model'
import {
  rowTarget,
  type SidebarFile,
  type SidebarNode,
  sidebarNodes,
  type SidebarSection as Section,
} from '~/lib/sidebars'
import { useObserve } from '~/lib/use-observe'
import { errorMessage } from '~/sdk/errors'
import { sqlSubscription } from '~/sdk/subscriptions'
import { SessionRow } from './session-row'

interface Navigation {
  group: string
  sessions: SessionRecord[] | null
  here: string
  collapsed: ReadonlySet<string>
  onToggle: (key: string) => void
  onNavigate: (to: string) => void
}

export function CustomSidebar(
  { file, ...navigation }: { file: SidebarFile } & Navigation,
) {
  if ('failure' in file) {
    return (
      <SidebarSection title={file.title}>
        <SidebarNote tone='alert'>{file.failure}</SidebarNote>
      </SidebarSection>
    )
  }
  return file.sections.map((section) => (
    <CustomSection key={section.id} section={section} {...navigation} />
  ))
}

const glyph: Record<'document' | 'table', IconName> = {
  document: 'note',
  table: 'table',
}

// Each section is its own live query; unmounting it on a view switch closes
// the observation.
function CustomSection({
  section,
  group,
  sessions,
  here,
  collapsed,
  onToggle,
  onNavigate,
}: { section: Section } & Navigation) {
  const observed = useObserve<QueryOutput | null, QueryOutput>(
    sqlSubscription(section.sql, group),
    (_, output) => output,
    null,
  )
  let nodes: SidebarNode[] | null = null
  let failure: string | null = null
  if (observed.data != null) {
    try {
      nodes = sidebarNodes(observed.data)
    } catch (refusal) {
      failure = errorMessage(refusal)
    }
  }
  const firstAgent =
    sessions?.find((session) =>
      session.group === group && session.kind === 'agent' &&
      session.lifecycle !== 'archived'
    )?.id ?? null
  const key = (id: string) => `${section.id}\n${id}`
  const rows = flatten(nest(nodes ?? []), (id) => !collapsed.has(key(id)))
    .flatMap((row) => {
      const target = rowTarget(row.item.destination, firstAgent, group)
      return target == null ? [] : [{ ...row, target }]
    })
  return (
    <SidebarSection title={section.title}>
      {observed.liveness !== 'live' && (
        <SidebarNote>Waiting for the space…</SidebarNote>
      )}
      {failure != null && <SidebarNote tone='alert'>{failure}</SidebarNote>}
      {nodes?.length === 0 && observed.liveness === 'live' && (
        <SidebarNote>No matches yet</SidebarNote>
      )}
      {rows.map(({ item, depth, hasChildren, open, target }) => {
        const shared = {
          depth,
          expanded: hasChildren ? open : undefined,
          active: here === target.href,
          onToggle: hasChildren ? () => onToggle(key(item.id)) : undefined,
        }
        const session = target.kind === 'session'
          ? sessions?.find((record) => record.id === target.id)
          : undefined
        if (session != null) {
          // Only a row naming the session's box carries its unread; `chat`
          // shows the agent it opens, not that agent's mail.
          return (
            <SessionRow
              key={item.id}
              session={item.destination === 'chat'
                ? { ...session, unread: false }
                : session}
              label={item.title}
              onNavigate={onNavigate}
              {...shared}
            />
          )
        }
        return (
          <SidebarRow
            key={item.id}
            label={item.title}
            title={item.destination}
            href={target.href}
            onClick={() => onNavigate(target.href)}
            mark={
              <span className='wui-mark-glyph' aria-hidden='true'>
                {target.kind === 'session' || target.kind === 'conversation'
                  ? initialsFrom(item.title)
                  : <Icon name={glyph[target.kind]} />}
              </span>
            }
            {...shared}
          />
        )
      })}
    </SidebarSection>
  )
}
