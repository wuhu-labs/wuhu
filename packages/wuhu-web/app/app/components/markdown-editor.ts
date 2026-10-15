import type { Editor, EditorOptions } from '@tiptap/core'
import CodeBlockLowlight from '@tiptap/extension-code-block-lowlight'
import { Mathematics } from '@tiptap/extension-mathematics'
import Placeholder from '@tiptap/extension-placeholder'
import { TableKit } from '@tiptap/extension-table'
import TaskItem from '@tiptap/extension-task-item'
import TaskList from '@tiptap/extension-task-list'
import { Markdown } from '@tiptap/markdown'
import StarterKit from '@tiptap/starter-kit'
import { common, createLowlight } from 'lowlight'
import { ContentMarks, SettleAfterDrop } from './editor-plugins'
import { SlashCommands } from './editor-slash'

const lowlight = createLowlight(common)

const extensions = [
  // A `wuhu:` link is a space link; without the scheme Tiptap drops its href.
  StarterKit.configure({
    codeBlock: false,
    link: {
      openOnClick: false,
      protocols: [{ scheme: 'wuhu', optionalSlashes: true }],
    },
  }),
  CodeBlockLowlight.configure({ lowlight }),
  Markdown,
  TaskList,
  TaskItem.configure({ nested: true }),
  Mathematics,
  TableKit.configure({ table: { resizable: true } }),
  Placeholder.configure({
    placeholder: ({ node }) =>
      node.type.name === 'heading'
        ? 'Heading'
        : 'Type / for a block, or just write',
  }),
  ContentMarks,
  SettleAfterDrop,
  SlashCommands,
]

export function markdownEditorOptions(
  content: string,
  editable: boolean,
  onChange: (markdown: string) => void,
): Partial<EditorOptions> {
  return {
    extensions,
    content,
    contentType: 'markdown',
    editable,
    onUpdate: ({ editor }) => onChange(editor.getMarkdown()),
  }
}

// Tiptap reports an editability flip as an update, which is not an edit.
export function setEditable(editor: Editor, editable: boolean) {
  editor.setEditable(editable, false)
}

export interface RemoteText {
  revision: number
  body: string
}

// Adopts text the editor didn't write, once per revision, and never under the
// cursor of someone typing. Returns the revision the editor now holds.
export function adoptRemote(
  editor: Editor,
  remote: RemoteText,
  held: number,
): number {
  if (remote.revision === held) return held
  if (editor.isEditable && editor.isFocused) return held
  editor.commands.setContent(remote.body, {
    contentType: 'markdown',
    emitUpdate: false,
  })
  return remote.revision
}
