import type {
  GroupDetail,
  GroupSummary,
  HiddenSidebarAddress,
} from './contract.gen.ts'
import { sharedGroup } from './groups.ts'
import { everything, type SidebarFile, type SidebarView } from './sidebars.ts'

export interface SidebarGroup {
  id: string
  label: string
  alias: string
  metadata?: 'loading' | 'failed'
  open: boolean | null
  role: 'Admin' | 'Member' | 'Read-only'
}

export type SidebarAddress = HiddenSidebarAddress

export type CatalogSidebar = SidebarFile & {
  group: SidebarGroup
  visible: boolean
}

export function sidebarKey(address: SidebarAddress): string {
  return `${address.group}:${address.path}`
}

export function sidebarGroups(
  summaries: readonly GroupSummary[],
  details: readonly GroupDetail[],
  failed: ReadonlySet<string> = new Set(),
): SidebarGroup[] {
  return summaries.filter((summary) => summary.readable).map((summary) => {
    const detail = details.find(({ id }) => id === summary.id)
    const alias = detail?.alias ?? summary.id
    return {
      id: summary.id,
      alias,
      label: summary.id === sharedGroup ? 'Shared' : alias,
      metadata: detail
        ? undefined
        : failed.has(summary.id)
        ? 'failed' as const
        : 'loading' as const,
      open: detail?.open ?? null,
      role: summary.admin
        ? 'Admin' as const
        : summary.member
        ? 'Member' as const
        : 'Read-only' as const,
    }
  }).sort((a, b) =>
    Number(b.id === sharedGroup) - Number(a.id === sharedGroup) ||
    a.alias.localeCompare(b.alias) || a.id.localeCompare(b.id)
  )
}

export function catalogSidebars(
  groups: readonly SidebarGroup[],
  files: (group: string) => readonly SidebarFile[] | null,
  hidden: readonly SidebarAddress[],
): CatalogSidebar[] {
  const keys = new Set(hidden.map(sidebarKey))
  return groups.flatMap((group) =>
    (files(group.id) ?? []).map((file) => ({
      ...file,
      group,
      visible: !keys.has(sidebarKey({ group: group.id, path: file.path })),
    }))
  )
}

export function namedSidebars(
  entries: readonly CatalogSidebar[],
  runtimeTitle: (entry: CatalogSidebar) => string | null,
): CatalogSidebar[] {
  const titles = entries.map((entry) =>
    (entry.visible &&
        !(entry.group.id === sharedGroup && entry.path === everything)
      ? runtimeTitle(entry)
      : null) ??
      entry.title
  )
  return entries.map((entry, index) => ({
    ...entry,
    title:
      titles.some((other, at) =>
          other === titles[index] && entries[at].group.id !== entry.group.id
        )
        ? `${titles[index]} · ${entry.group.label}`
        : titles[index],
  }))
}

export function sidebarScripts(
  entries: readonly CatalogSidebar[],
): SidebarAddress[] {
  return entries.filter((entry) => entry.visible && 'script' in entry).map((
    entry,
  ) => ({ group: entry.group.id, path: entry.path }))
}

export function sidebarGroupRows(
  groups: readonly SidebarGroup[],
  entries: readonly CatalogSidebar[],
  asked: string | null,
  loaded: (id: string) => boolean = () => true,
) {
  const selected = groups.find(({ id }) => id === asked)?.id ?? groups[0]?.id
  return groups.map((group) => ({
    ...group,
    selected: group.id === selected,
    loading: !loaded(group.id),
    sidebars: entries.filter((entry) => entry.group.id === group.id),
  }))
}

export function selectedSidebar(
  entries: readonly CatalogSidebar[] | null,
  view: SidebarView,
): CatalogSidebar | null {
  const visible = entries?.filter((entry) => entry.visible) ?? []
  return visible.find((entry) =>
    entry.group.id === view.group && entry.path === view.sidebar
  ) ?? visible[0] ?? null
}
