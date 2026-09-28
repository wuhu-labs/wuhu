import type {
  SessionToolExecutor,
  ToolDescriptor,
  ToolRosterDescriptor,
} from './contract.gen.ts'

export const executors: { executor: SessionToolExecutor; label: string }[] = [
  { executor: 'kernel', label: 'Kernel' },
  { executor: 'claude-code', label: 'Claude Code' },
]

export function rosterTools(
  rosters: ToolRosterDescriptor[],
  executor: SessionToolExecutor,
): ToolDescriptor[] {
  return rosters.find((roster) => roster.executor === executor)?.tools ?? []
}

export function matchingTools(
  tools: ToolDescriptor[],
  query: string,
): ToolDescriptor[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return tools
  return tools.filter((tool) =>
    tool.name.toLowerCase().includes(needle) ||
    tool.description.toLowerCase().includes(needle)
  )
}

export function rosterSummary(
  rosters: ToolRosterDescriptor[],
  executor: SessionToolExecutor,
): string {
  const mine = rosterTools(rosters, executor)
  const count = `${mine.length} tool${mine.length === 1 ? '' : 's'}`
  const elsewhere = new Set(
    rosters.filter((roster) => roster.executor !== executor)
      .flatMap((roster) => roster.tools.map((tool) => tool.name)),
  )
  const only = mine.map((tool) => tool.name).filter((name) =>
    !elsewhere.has(name)
  )
  if (rosters.length < 2 || only.length === 0) return count
  return `${count}; ${executor}-only: ${only.join(', ')}`
}
