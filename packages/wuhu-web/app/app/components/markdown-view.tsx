import type { Element, ElementContent } from 'hast'
import { useMemo, useState } from 'react'
import ReactMarkdown, {
  type Components,
  defaultUrlTransform,
} from 'react-markdown'
import { Link, useOutletContext } from 'react-router'
import remarkGfm from 'remark-gfm'
import { splitFrontmatter } from '~/lib/frontmatter'
import { spaceLink } from '~/lib/links'
import { remarkBlocks } from '~/lib/markdown-blocks'
import type { SpaceContext } from '~/routes/space'

const remarkPlugins = [remarkGfm, remarkBlocks]

function textOf(node: ElementContent): string {
  if (node.type === 'text') return node.value
  if (node.type === 'element') return node.children.map(textOf).join('')
  return ''
}

function codeLanguage(code: Element | undefined): string | undefined {
  const classes = code?.properties.className
  if (!Array.isArray(classes)) return undefined
  const match = classes.map(String).find((name) => name.startsWith('language-'))
  return match?.slice('language-'.length)
}

function CopyCode({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <button
      type='button'
      className='wuhu-code-copy'
      aria-label='Copy code'
      data-copied={copied}
      onClick={() => {
        void navigator.clipboard.writeText(text).then(() => {
          setCopied(true)
          setTimeout(() => setCopied(false), 1200)
        })
      }}
    >
      {copied ? 'Copied' : 'Copy'}
    </button>
  )
}

const blockComponents: Components = {
  pre({ node, children }) {
    const code = node?.children.find(
      (child): child is Element =>
        child.type === 'element' && child.tagName === 'code',
    )
    return (
      <figure className='wuhu-code' data-lang={codeLanguage(code)}>
        <figcaption>
          <span>{codeLanguage(code)}</span>
          <CopyCode text={code == null ? '' : textOf(code)} />
        </figcaption>
        <pre>{children}</pre>
      </figure>
    )
  },
  table({ node: _node, ...props }) {
    return (
      <div className='wuhu-table-wrap'>
        <table {...props} />
      </div>
    )
  },
}

// react-markdown blanks every scheme it doesn't know, `wuhu:` included.
function keepSpaceLinks(url: string): string {
  return /^wuhu:/i.test(url) ? url : defaultUrlTransform(url)
}

export function Markdown({
  children,
  sourcePath,
}: {
  children: string
  sourcePath?: string
}) {
  const { group, contentHost } = useOutletContext<SpaceContext>()
  const components = useMemo<Components>(
    () => ({
      ...blockComponents,
      a({ node: _node, href, children: label, ...props }) {
        const to = href == null
          ? null
          : spaceLink(href, group, sourcePath, { contentHost })
        if (to == null) {
          return (
            <a href={href} {...props}>
              {label}
            </a>
          )
        }
        return (
          <Link to={to} {...props}>
            {label}
          </Link>
        )
      },
    }),
    [group, sourcePath, contentHost],
  )
  return (
    // Raw HTML in markdown stays inert: no rehype-raw, so react-markdown drops
    // it instead of injecting it into the DOM.
    <ReactMarkdown
      remarkPlugins={remarkPlugins}
      components={components}
      urlTransform={keepSpaceLinks}
    >
      {children}
    </ReactMarkdown>
  )
}

// A stored document carries its frontmatter; rendering it as markdown turns the
// closing `---` into a setext heading. The block is metadata, so it leaves the
// body and comes back as <DocMeta>.
export function MarkdownView({
  content,
  sourcePath,
}: {
  content: string
  sourcePath?: string
}) {
  const { body } = splitFrontmatter(content)
  return (
    <article className='wuhu-markdown'>
      <Markdown sourcePath={sourcePath}>{body}</Markdown>
    </article>
  )
}
