export const widgetSizes: readonly ['wide', 'small']
export const templates: readonly ['Subject', 'Agent', 'Figure', 'Doc', 'List', 'Pattern', 'Progress', 'Calendar', 'Entity']
export class TreeError extends Error {}
export function knownIcon(name: string): boolean
export function sidebarTree(value: unknown): unknown
export function widgetTree(value: unknown, sizes: unknown, size: 'wide' | 'small'): unknown
