import type { ReactNode } from 'react'

function Block(
  { id, label, source, wide, children }: {
    id: string
    label: string
    source: string
    wide?: boolean
    children: ReactNode
  },
) {
  return (
    <section className='lab-block' id={id} data-block={id}>
      <header className='lab-block-head'>
        <span className='lab-block-label'>{label}</span>
        <code className='lab-block-source'>{source}</code>
      </header>
      <div
        className={wide
          ? 'wuhu-content lab-block-body lab-block-wide'
          : 'wuhu-content lab-block-body'}
      >
        {children}
      </div>
    </section>
  )
}

function Md({ children }: { children: ReactNode }) {
  return <article className='wuhu-markdown'>{children}</article>
}

function Code({ lang, children }: { lang?: string; children: string }) {
  return (
    <figure className='wuhu-code' data-lang={lang}>
      <figcaption>
        <span>{lang}</span>
        <button type='button' className='wuhu-code-copy' aria-label='Copy code'>
          Copy
        </button>
      </figcaption>
      <pre>
        <code className={lang ? `language-${lang}` : undefined}>{children}</code>
      </pre>
    </figure>
  )
}

const lanes: [string, string[]][] = [
  ['todo', [
    'Write the blocks spec',
    'Port callouts to SwiftUI',
    'Kanban drag',
  ]],
  ['doing', ['Web renderer: figures and footnotes']],
  ['review', []],
  ['done', ['Tokens: amber + alert', 'Data table density pass']],
]

const rows: [number, string, string, number | null, boolean][] = [
  [1, 'Write the blocks spec', 'todo', 1, false],
  [2, 'Port callouts to SwiftUI', 'todo', 2, false],
  [3, 'Web renderer: figures and footnotes', 'doing', 1, true],
  [4, 'Tokens: amber + alert', 'done', null, true],
  [5, 'Data table density pass', 'done', 3, true],
]

const figureSvg =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 640 300'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' x2='1'%3E%3Cstop offset='0' stop-color='%2357c3a1'/%3E%3Cstop offset='.6' stop-color='%237570e6'/%3E%3Cstop offset='1' stop-color='%23b3679d'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='640' height='300' fill='url(%23g)'/%3E%3Ccircle cx='470' cy='120' r='70' fill='white' fill-opacity='.35'/%3E%3C/svg%3E"

export function BlocksPage() {
  return (
    <div className='lab-blocks'>
      <div className='lab-eyebrow'>Living artifact · Content blocks</div>
      <h1 className='lab-blocks-title'>Every block wuhu renders</h1>
      <p className='lab-blocks-lede'>
        One vocabulary for markdown documents, transcripts and data views. The
        web renderer ships exactly this CSS (<code>@wuhu/ui/content.css</code>);
        the native app ports from it.
      </p>

      <Block
        id='paragraph'
        label='Paragraph & inline'
        source='**bold** *em* ~~del~~ `code` [link](/notes) @alex'
      >
        <Md>
          <p>
            Body text sits at 1rem on a 1.65 line. Emphasis is{' '}
            <strong>bold at 650</strong>, <em>italic</em>{' '}
            stays the same weight, and <del>struck text</del>{' '}
            drops to muted. Inline <code>code</code>{' '}
            is a mono chip on the code tint. Links to{' '}
            <a href='/doc'>space paths</a>{' '}
            take the accent with a hairline underline, and a mention like{' '}
            <span className='wuhu-mention'>@alex</span> or{' '}
            <span className='wuhu-mention'>@session-7f3a</span>{' '}
            is an accent chip that never wraps.
          </p>
          <p>
            A second paragraph opens a 1.2rem gap — the block rhythm every
            top-level element shares.
          </p>
        </Md>
      </Block>

      <Block
        id='headings'
        label='Headings h1–h4'
        source='# … ## … ### … #### …'
      >
        <Md>
          <h1>Heading one, 1.75rem</h1>
          <p>Only the document title is this large; it carries -0.025em.</p>
          <h2>Heading two, 1.4rem</h2>
          <p>Sections. 2.4rem above, 0.85rem to the first paragraph.</p>
          <h3>Heading three, 1.1rem</h3>
          <p>Subsections keep the body's letter-spacing.</p>
          <h4>Heading four, 0.95rem</h4>
          <p>A run-in label; h5 and h6 render the same.</p>
        </Md>
      </Block>

      <Block
        id='lists'
        label='Lists: bullets, numbers, nesting, tasks'
        source='- item / 1. item / - [x] done'
      >
        <Md>
          <ul>
            <li>Bullets use a muted disc marker</li>
            <li>
              Items sit 0.3rem apart
              <ul>
                <li>Nested lists indent 1.5rem</li>
                <li>
                  and keep the rhythm
                  <ul>
                    <li>at every depth</li>
                  </ul>
                </li>
              </ul>
            </li>
          </ul>
          <ol>
            <li>Numbered lists share the marker color</li>
            <li>
              Multi-paragraph items
              <p>keep a 0.3rem gap between paragraphs.</p>
            </li>
          </ol>
          <ul className='contains-task-list'>
            <li className='task-list-item'>
              <input type='checkbox' disabled checked readOnly />{' '}
              Done items go muted, no strike
            </li>
            <li className='task-list-item'>
              <input type='checkbox' disabled readOnly /> Open item
            </li>
            <li className='task-list-item'>
              <input type='checkbox' disabled readOnly />{' '}
              A long open item wraps under its own text, never under the box,
              because the row is a flex pair.
            </li>
          </ul>
        </Md>
      </Block>

      <Block id='blockquote' label='Blockquote' source='> quoted text'>
        <Md>
          <blockquote>
            <p>
              A quote is a 2px rule on the strong border and the lede grey. It
              is for someone else's words, not for emphasis.
            </p>
            <p>Second paragraph keeps the rhythm.</p>
          </blockquote>
        </Md>
      </Block>

      <Block
        id='callouts'
        label='Callouts'
        source='> [!NOTE] / [!TIP] / [!IMPORTANT] / [!WARNING] / [!CAUTION]'
      >
        <Md>
          <blockquote
            className='wuhu-callout'
            data-kind='note'
            data-title='Note'
          >
            <p>
              Note is the neutral aside: a blue tint at 9%, the title in the
              tone mixed toward ink.
            </p>
          </blockquote>
          <blockquote className='wuhu-callout' data-kind='tip' data-title='Tip'>
            <p>Tip takes mint-deep, the same accent links use.</p>
          </blockquote>
          <blockquote
            className='wuhu-callout'
            data-kind='important'
            data-title='Important'
          >
            <p>Important is violet.</p>
          </blockquote>
          <blockquote
            className='wuhu-callout'
            data-kind='warning'
            data-title='Warning'
          >
            <p>
              Warning is amber. Callouts hold any block:
            </p>
            <ul>
              <li>lists</li>
              <li>
                and <code>code</code>
              </li>
            </ul>
          </blockquote>
          <blockquote
            className='wuhu-callout'
            data-kind='caution'
            data-title='Caution'
          >
            <p>Caution is the alert red.</p>
          </blockquote>
        </Md>
      </Block>

      <Block
        id='code'
        label='Fenced code'
        source='```swift … ``` (label from the info string; copy on hover)'
      >
        <Md>
          <Code lang='swift'>
            {`struct Block: Identifiable {
  let id: String
  let kind: Kind
}

// A long line shows the figure scrolling horizontally instead of wrapping or widening the column.`}
          </Code>
          <Code>{`$ wuhu read /notes/plan.md\n---\ntitle: Plan`}</Code>
        </Md>
      </Block>

      <Block
        id='table'
        label='Markdown table'
        source='| a | b | with header, overflow-x'
      >
        <Md>
          <div className='wuhu-table-wrap'>
            <table>
              <thead>
                <tr>
                  <th>Block</th>
                  <th>Selector</th>
                  <th>Rhythm</th>
                  <th>Notes</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>Paragraph</td>
                  <td>
                    <code>.wuhu-markdown p</code>
                  </td>
                  <td>1.2rem</td>
                  <td>Base measure for everything else</td>
                </tr>
                <tr>
                  <td>Callout</td>
                  <td>
                    <code>blockquote.wuhu-callout</code>
                  </td>
                  <td>1.2rem</td>
                  <td>Tinted at 9% of the tone, title from data-title</td>
                </tr>
                <tr>
                  <td>Figure</td>
                  <td>
                    <code>figure.wuhu-figure</code>
                  </td>
                  <td>1.5rem</td>
                  <td>Image-only paragraph with alt text becomes a figure</td>
                </tr>
              </tbody>
            </table>
          </div>
        </Md>
      </Block>

      <Block
        id='figure'
        label='Image & figure'
        source='![Gradient study, three tokens](…) alone in a paragraph'
      >
        <Md>
          <figure className='wuhu-figure'>
            <img src={figureSvg} alt='Gradient study, three tokens' />
            <figcaption>Gradient study, three tokens</figcaption>
          </figure>
          <p>
            An inline image{' '}
            <img
              src={figureSvg}
              alt=''
              style={{ width: '4rem', verticalAlign: 'middle' }}
            />{' '}
            stays inline; only an image alone in a paragraph, with alt text, is
            a figure.
          </p>
        </Md>
      </Block>

      <Block id='rule' label='Horizontal rule' source='---'>
        <Md>
          <p>Before the rule.</p>
          <hr />
          <p>After: 2.2rem on both sides, a hairline on the border token.</p>
        </Md>
      </Block>

      <Block id='footnotes' label='Footnotes' source='text[^1] … [^1]: note'>
        <Md>
          <p>
            Footnotes are a mono superscript
            <sup>
              <a href='#fn-1' id='fnref-1' data-footnote-ref>1</a>
            </sup>{' '}
            and collect at the end of the document
            <sup>
              <a href='#fn-2' id='fnref-2' data-footnote-ref>2</a>
            </sup>.
          </p>
          <section data-footnotes className='footnotes'>
            <h2 id='footnote-label'>Footnotes</h2>
            <ol>
              <li id='fn-1'>
                <p>
                  The first note.{' '}
                  <a href='#fnref-1' data-footnote-backref aria-label='Back'>
                    ↩
                  </a>
                </p>
              </li>
              <li id='fn-2'>
                <p>
                  The second note.{' '}
                  <a href='#fnref-2' data-footnote-backref aria-label='Back'>
                    ↩
                  </a>
                </p>
              </li>
            </ol>
          </section>
        </Md>
      </Block>

      <Block
        id='data-table'
        label='View: data table (.table / SQL)'
        source={`wuhu query 'SELECT * FROM "/tasks.table"'`}
        wide
      >
        <div className='wuhu-table'>
          <table>
            <thead>
              <tr>
                <th>id</th>
                <th>title</th>
                <th>status</th>
                <th>priority</th>
                <th>shipped</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(([id, title, status, priority, shipped]) => (
                <tr key={id}>
                  <td data-type='number'>{id}</td>
                  <td data-type='string'>{title}</td>
                  <td data-type='string'>{status}</td>
                  <td data-type={priority == null ? 'null' : 'number'}>
                    {priority}
                  </td>
                  <td data-type='boolean'>{String(shipped)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className='wuhu-table-foot'>5 rows</p>
        </div>
      </Block>

      <Block
        id='data-table-empty'
        label='View: data table, empty'
        source='SELECT … WHERE 0'
        wide
      >
        <div className='wuhu-table'>
          <table>
            <thead>
              <tr>
                <th>id</th>
                <th>title</th>
                <th>status</th>
              </tr>
            </thead>
            <tbody></tbody>
          </table>
          <p className='wuhu-table-foot'>No rows</p>
        </div>
      </Block>

      <Block
        id='kanban'
        label='View: kanban (.view)'
        source='{"view":"kanban","config":{"groupBy":"status","cardTitle":"title"}}'
        wide
      >
        <div className='wuhu-kanban'>
          <main className='kanban-board'>
            {lanes.map(([lane, cards]) => (
              <section className='kanban-lane' key={lane} data-lane={lane}>
                <h2 className='kanban-lane-title'>
                  {lane}
                  <span className='kanban-lane-count'>{cards.length}</span>
                </h2>
                {cards.length === 0
                  ? <p className='kanban-empty'>Empty</p>
                  : cards.map((card) => (
                    <article className='kanban-card' key={card}>{card}</article>
                  ))}
              </section>
            ))}
          </main>
        </div>
      </Block>
    </div>
  )
}
