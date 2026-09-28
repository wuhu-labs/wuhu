import { Icon, type IconName, SidebarNote, SidebarRow } from '@wuhu/ui'
import { fileHref } from '~/lib/links'
import type { EntryKind } from '~/lib/contract.gen'
import type { TreeNode } from '~/lib/tree'

const iconFor: Record<EntryKind, IconName> = {
  directory: 'folder',
  table: 'table',
  file: 'note',
  symlink: 'note',
}

function GlyphMark({ kind }: { kind: EntryKind }) {
  return (
    <span className='wui-mark-glyph' aria-hidden='true'>
      <Icon name={iconFor[kind]} />
    </span>
  )
}

function parentOf(path: string): string {
  const end = path.lastIndexOf('/')
  return end === 0 ? '/' : path.slice(0, end)
}

export function SpaceTree({
  tree,
  group,
  activePath,
  expanded,
  onToggle,
  onNavigate,
  onNewDocument,
}: {
  tree: TreeNode[]
  group: string
  activePath: string | null
  expanded: ReadonlySet<string>
  onToggle: (path: string) => void
  onNavigate: (path: string) => void
  onNewDocument: (directory: string, group: string) => void
}) {
  if (tree.length === 0) return <SidebarNote>Empty space</SidebarNote>
  return (
    <>
      {tree.map((node) => (
        <Row
          key={node.path}
          node={node}
          group={group}
          depth={0}
          activePath={activePath}
          expanded={expanded}
          onToggle={onToggle}
          onNavigate={onNavigate}
          onNewDocument={onNewDocument}
        />
      ))}
    </>
  )
}

function Row({
  node,
  group,
  depth,
  activePath,
  expanded,
  onToggle,
  onNavigate,
  onNewDocument,
}: {
  node: TreeNode
  group: string
  depth: number
  activePath: string | null
  expanded: ReadonlySet<string>
  onToggle: (path: string) => void
  onNavigate: (path: string) => void
  onNewDocument: (directory: string, group: string) => void
}) {
  if (node.kind === 'directory') {
    const open = expanded.has(node.path)
    return (
      <>
        <SidebarRow
          label={node.name}
          title={node.path}
          mark={<GlyphMark kind={node.kind} />}
          depth={depth}
          expanded={open}
          active={activePath === node.path}
          menu={[
            {
              label: 'New document',
              icon: 'note',
              onSelect: () => onNewDocument(node.path, group),
            },
          ]}
          onClick={() => onToggle(node.path)}
          onToggle={() => onToggle(node.path)}
        />
        {open &&
          node.children.map((child) => (
            <Row
              key={child.path}
              node={child}
              group={group}
              depth={depth + 1}
              activePath={activePath}
              expanded={expanded}
              onToggle={onToggle}
              onNavigate={onNavigate}
              onNewDocument={onNewDocument}
            />
          ))}
      </>
    )
  }
  return (
    <SidebarRow
      label={node.name}
      title={node.path}
      mark={<GlyphMark kind={node.kind} />}
      depth={depth}
      href={fileHref(node.path, group)}
      active={activePath === node.path}
      menu={[
        {
          label: 'New document',
          icon: 'note',
          onSelect: () => onNewDocument(parentOf(node.path), group),
        },
      ]}
      onClick={() => onNavigate(fileHref(node.path, group))}
    />
  )
}
