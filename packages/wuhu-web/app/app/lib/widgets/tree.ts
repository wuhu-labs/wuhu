import * as shared from './shared/tree.js'

export interface Element {
  $element: string
  props: Record<string, unknown>
}

export interface PageEntry {
  page?: string
  title?: string
  status?: string
  badge?: number
  avatar?: string
}

export interface PageCardSpec extends PageEntry {
  children: PageEntry[]
}

export type WidgetSize = 'wide' | 'small'

export const widgetSizes: readonly WidgetSize[] = shared.widgetSizes

export type SidebarItem =
  | { kind: 'page'; card: PageCardSpec }
  | { kind: 'widget'; src: string; size: WidgetSize }

export interface SidebarTree {
  name: string
  icon: string | null
  home: string | null
  items: SidebarItem[]
}

export const templates = shared.templates as readonly [
  'Subject',
  'Agent',
  'Figure',
  'Doc',
  'List',
  'Pattern',
  'Progress',
  'Calendar',
  'Entity',
]

export type TemplateName = typeof templates[number]

export const TreeError = shared.TreeError
export const knownIcon: (name: string) => boolean = shared.knownIcon
export const sidebarTree: (value: unknown) => SidebarTree = shared
  .sidebarTree as (value: unknown) => SidebarTree
export const widgetTree: (
  value: unknown,
  sizes: unknown,
  size: WidgetSize,
) => Element = shared.widgetTree as (
  value: unknown,
  sizes: unknown,
  size: WidgetSize,
) => Element
