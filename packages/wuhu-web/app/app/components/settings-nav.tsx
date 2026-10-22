import { Icon, ListCard, Row } from '@wuhu/ui'
import { Avatar } from '~/components/avatar'
import { aiSharing } from '~/lib/ai-sharing'
import { sendKeyLabel, useSendKey } from '~/lib/composer'
import { handleFor } from '~/lib/directory'
import { screens } from '~/lib/links'
import { useDirectory, useOwnPrincipal } from '~/lib/use-directory'

// Settings is two topics on the rail, each a card of one-line rows whose
// detail draws on the right.
export const settingsTopics = {
  you: { label: 'You', rows: ['profile', 'devices', 'browser', 'ai-sharing'] },
  space: { label: 'Space', rows: ['templates', 'usage'] },
} as const

export type SettingsTopic = keyof typeof settingsTopics
export type SettingsRow = (typeof settingsTopics)[SettingsTopic]['rows'][number]

const rowLabels: Record<SettingsRow, string> = {
  profile: 'Profile',
  devices: 'Devices',
  browser: 'This browser',
  'ai-sharing': 'AI sharing',
  templates: 'Session templates',
  usage: 'Usage',
}

export function settingsRowLabel(row: SettingsRow): string {
  return rowLabels[row]
}

export function settingsHref(topic: SettingsTopic, row?: SettingsRow): string {
  const params = new URLSearchParams({ topic })
  if (row) params.set('row', row)
  return `${screens.settings}?${params}`
}

// The topic and row a settings address names; the topic's first row when it
// names none.
export function settingsPlace(
  search: string,
): { topic: SettingsTopic; row: SettingsRow } {
  const params = new URLSearchParams(search)
  const topic: SettingsTopic = params.get('topic') === 'space' ? 'space' : 'you'
  const rows: readonly SettingsRow[] = settingsTopics[topic].rows
  const asked = params.get('row') as SettingsRow | null
  return { topic, row: asked && rows.includes(asked) ? asked : rows[0] }
}

export function SettingsRail({
  topic,
  onNavigate,
}: {
  topic: SettingsTopic
  onNavigate: (href: string) => void
}) {
  const principal = useOwnPrincipal()
  return (
    <>
      <button
        type='button'
        title='You'
        aria-label='You'
        aria-pressed={topic === 'you'}
        onClick={() => onNavigate(settingsHref('you'))}
      >
        <Avatar principal={principal} size={28} />
      </button>
      <button
        type='button'
        title='Space'
        aria-label='Space'
        aria-pressed={topic === 'space'}
        onClick={() => onNavigate(settingsHref('space'))}
      >
        <Icon name='grid' w={17} h={17} />
      </button>
    </>
  )
}

function useRowValue(row: SettingsRow): string | null {
  const directory = useDirectory()
  const principal = useOwnPrincipal()
  const sendKey = useSendKey()
  switch (row) {
    case 'profile': {
      const handle = principal == null ? null : handleFor(directory, principal)
      return handle == null ? null : `@${handle}`
    }
    case 'browser':
      return sendKeyLabel(sendKey)
    case 'ai-sharing': {
      const decision = aiSharing()
      return decision === 'allowed'
        ? 'Allowed'
        : decision === 'declined'
        ? 'Declined'
        : 'Not decided'
    }
    default:
      return null
  }
}

function SettingsRowLink({
  topic,
  row,
  current,
  onNavigate,
}: {
  topic: SettingsTopic
  row: SettingsRow
  current: boolean
  onNavigate: (href: string) => void
}) {
  const value = useRowValue(row)
  return (
    <Row
      href={settingsHref(topic, row)}
      current={current}
      onNavigate={onNavigate}
      label={settingsRowLabel(row)}
      trail={value}
    />
  )
}

export function SettingsSidebar({
  topic,
  row,
  onNavigate,
}: {
  topic: SettingsTopic
  row: SettingsRow
  onNavigate: (href: string) => void
}) {
  return (
    <ListCard title={settingsTopics[topic].label}>
      {settingsTopics[topic].rows.map((option) => (
        <SettingsRowLink
          key={option}
          topic={topic}
          row={option}
          current={option === row}
          onNavigate={onNavigate}
        />
      ))}
    </ListCard>
  )
}
