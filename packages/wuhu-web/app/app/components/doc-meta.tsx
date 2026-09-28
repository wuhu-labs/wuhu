import { Pill } from '@wuhu/ui'
import { PageHeading } from '~/components/page-heading'
import { attrValue } from '~/lib/frontmatter'
import type { QueryOutput } from '~/lib/contract.gen'
import { useObserve } from '~/lib/use-observe'
import { sqlSubscription } from '~/sdk/subscriptions'

interface Attr {
  name: string
  values: string[]
}

interface DocMetaData {
  kind: string | null
  status: string | null
  attrs: Attr[]
}

const empty: DocMetaData = { kind: null, status: null, attrs: [] }

export function documentName(path: string): string {
  const name = path.slice(path.lastIndexOf('/') + 1)
  return name.replace(/\.(md|markdown)$/, '')
}

// Frontmatter is parsed once, by the space, into docs / doc_custom_attrs. The
// page renders that index rather than re-parsing YAML in the browser, so the
// two can never disagree.
function query(path: string): string {
  const quoted = path.replaceAll("'", "''")
  return `SELECT docs.kind, docs.status, doc_custom_attrs.name, doc_custom_attrs.value
FROM docs LEFT JOIN doc_custom_attrs ON doc_custom_attrs.path = docs.path
WHERE docs.path = '${quoted}'
ORDER BY doc_custom_attrs.name, doc_custom_attrs.ord`
}

function collect(output: QueryOutput): DocMetaData {
  const first = output.rows[0]
  if (!first) return empty
  const attrs: Attr[] = []
  for (const row of output.rows) {
    if (row[2] == null) continue
    const name = String(row[2])
    const last = attrs.at(-1)
    if (last?.name === name) last.values.push(String(row[3]))
    else attrs.push({ name, values: [String(row[3])] })
  }
  return {
    kind: first[0] == null ? null : String(first[0]),
    status: first[1] == null ? null : String(first[1]),
    attrs,
  }
}

const statusTone = (status: string) =>
  status === 'blocked' || status === 'failed'
    ? 'rose'
    : status === 'active' || status === 'in-progress' || status === 'wip'
    ? 'amber'
    : 'neutral'

export function DocMeta({ path, group }: { path: string; group: string }) {
  const meta = useObserve<DocMetaData, QueryOutput>(
    sqlSubscription(query(path), group),
    (_, output) => collect(output),
    empty,
  ).data

  const rawTitle = meta.attrs.find((attr) => attr.name === 'title')?.values[0]
  const title = rawTitle == null ? null : attrValue(rawTitle).text
  const attrs = meta.attrs.filter((attr) => attr.name !== 'title')
  const bare = meta.kind == null && meta.status == null && attrs.length === 0
  return (
    <>
      <PageHeading
        className='wuhu-doc-title'
        title={title ?? documentName(path)}
        group={group}
      />
      {!bare && (
        <section className='wuhu-frontmatter' aria-label='Document metadata'>
          {(meta.kind != null || meta.status != null) && (
            <div className='wuhu-frontmatter-pills'>
              {meta.kind != null && <Pill>{meta.kind}</Pill>}
              {meta.status != null && (
                <Pill tone={statusTone(meta.status)} dot>{meta.status}</Pill>
              )}
            </div>
          )}
          {attrs.length > 0 && (
            <dl className='wuhu-attrs'>
              {attrs.map((attr) => (
                <div key={attr.name} style={{ display: 'contents' }}>
                  <dt>{attr.name}</dt>
                  <dd>
                    <AttrValues values={attr.values} />
                  </dd>
                </div>
              ))}
            </dl>
          )}
        </section>
      )}
    </>
  )
}

function AttrValues({ values }: { values: string[] }) {
  const parsed = values.map(attrValue)
  if (parsed.length === 1 && parsed[0].kind === 'json') {
    return <pre className='wuhu-attr-json'>{parsed[0].text}</pre>
  }
  if (parsed.length === 1) return <>{parsed[0].text}</>
  return (
    <span className='wuhu-attr-values'>
      {parsed.map((value, index) => <Pill key={index}>{value.text}</Pill>)}
    </span>
  )
}
