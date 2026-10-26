import type {
  GroupDetail,
  GroupSummary,
  ReadOutput,
  WriteInput,
} from './contract.gen.ts'
import { ApiError } from '~/sdk/errors'
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

export interface SidebarAddress {
  group: string
  path: string
}

export type CatalogSidebar = SidebarFile & {
  group: SidebarGroup
  visible: boolean
}

export const sidebarSettingsPath = '/.settings/sidebars.json'

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

export function hiddenSidebars(content: string): SidebarAddress[] {
  const value: unknown = JSON.parse(content)
  if (
    typeof value !== 'object' || value === null || !('hidden' in value) ||
    !Array.isArray(value.hidden) ||
    !value.hidden.every((entry: unknown) =>
      typeof entry === 'object' && entry !== null && 'group' in entry &&
      typeof entry.group === 'string' && 'path' in entry &&
      typeof entry.path === 'string'
    )
  ) throw new Error("Sidebar settings can't be read")
  return value.hidden
}

export interface SidebarPreferences {
  hidden: SidebarAddress[]
  error: string | null
}

export function readSidebarPreferences(
  previous: SidebarPreferences,
  content: string | null,
): SidebarPreferences {
  try {
    return {
      hidden: content === null ? [] : hiddenSidebars(content),
      error: null,
    }
  } catch {
    return { ...previous, error: "Sidebar settings can't be read" }
  }
}

export function changeSidebarVisibility(
  hidden: readonly SidebarAddress[],
  address: SidebarAddress,
  visible: boolean,
): SidebarAddress[] {
  const rest = hidden.filter((entry) =>
    sidebarKey(entry) !== sidebarKey(address)
  )
  return visible ? rest : [...rest, address]
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

export async function writeSidebarVisibility(
  io: {
    read(): Promise<ReadOutput | null>
    write(input: WriteInput): Promise<unknown>
  },
  address: SidebarAddress,
  visible: boolean,
): Promise<SidebarAddress[]> {
  for (let attempt = 0;; attempt++) {
    const current = await io.read()
    const hidden = changeSidebarVisibility(
      current === null ? [] : hiddenSidebars(current.content),
      address,
      visible,
    )
    const document = current === null ? {} : JSON.parse(current.content)
    try {
      await io.write({
        path: sidebarSettingsPath,
        content: JSON.stringify({ ...document, hidden }),
        ...(current === null
          ? { createOnly: true }
          : { ifMatch: current.token }),
      })
      return hidden
    } catch (failure) {
      if (
        !(failure instanceof ApiError && failure.code === 'conflict') ||
        attempt > 0
      ) throw failure
    }
  }
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
