import { useState } from 'react'

interface ColorToken {
  name: string
  cssVar: string
  role: string
}

const inks: ColorToken[] = [
  { name: 'Ink', cssVar: '--color-ink', role: 'text, marks' },
  { name: 'Ink surface', cssVar: '--color-ink-surface', role: 'dark cards' },
  { name: 'Grey strong', cssVar: '--color-grey-strong', role: 'emphasis body' },
  { name: 'Grey lede', cssVar: '--color-grey-lede', role: 'ledes, subtitles' },
  { name: 'Grey muted', cssVar: '--color-grey-muted', role: 'secondary text' },
  { name: 'Grey faint', cssVar: '--color-grey-faint', role: 'labels, meta' },
  {
    name: 'Grey idle',
    cssVar: '--color-grey-idle',
    role: 'disabled, idle dots',
  },
]

const papers: ColorToken[] = [
  { name: 'Paper', cssVar: '--color-paper', role: 'base' },
  {
    name: 'Canvas warm',
    cssVar: '--color-canvas-warm',
    role: 'gradient start',
  },
  {
    name: 'Canvas green',
    cssVar: '--color-canvas-green',
    role: 'gradient mid',
  },
  { name: 'Canvas rose', cssVar: '--color-canvas-rose', role: 'gradient end' },
]

const accents: ColorToken[] = [
  { name: 'Mint', cssVar: '--color-mint', role: 'brand, live' },
  { name: 'Mint deep', cssVar: '--color-mint-deep', role: 'eyebrow text' },
  {
    name: 'Green confirm',
    cssVar: '--color-green-confirm',
    role: 'checks, success',
  },
  { name: 'Blue', cssVar: '--color-blue', role: 'agents, links' },
  { name: 'Violet', cssVar: '--color-violet', role: 'agents alt' },
  {
    name: 'Indigo chart',
    cssVar: '--color-indigo-chart',
    role: 'chart fills only',
  },
  { name: 'Rose', cssVar: '--color-rose', role: 'gradient tail' },
]

function useTokenValues(tokens: ColorToken[]): Record<string, string> {
  const [values] = useState<Record<string, string>>(() => {
    const style = getComputedStyle(document.documentElement)
    return Object.fromEntries(
      tokens.map((
        token,
      ) => [token.cssVar, style.getPropertyValue(token.cssVar).trim()]),
    )
  })
  return values
}

function SwatchGrid(
  { tokens, hairline }: { tokens: ColorToken[]; hairline?: boolean },
) {
  const values = useTokenValues(tokens)
  return (
    <div className='lab-swatches'>
      {tokens.map((token) => (
        <figure key={token.cssVar} className='lab-swatch'>
          <div
            className={hairline ? 'lab-chip lab-hairline' : 'lab-chip'}
            style={{ background: `var(${token.cssVar})` }}
          />
          <figcaption>
            <span className='lab-name'>{token.name}</span>
            <span className='lab-value'>
              {values[token.cssVar] ?? '…'} · {token.role}
            </span>
          </figcaption>
        </figure>
      ))}
    </div>
  )
}

export function TokensPage() {
  return (
    <div className='lab-inner lab-board'>
      <section>
        <div className='lab-eyebrow'>Design tokens · Moodboard</div>
        <h1 className='lab-display lab-compact'>
          Thirty-two colors, <br />one temperament.
        </h1>
        <p className='lab-lede'>
          Values read live from <code>@wuhu/ui/tokens.css</code>{' '}
          — this page cannot drift from the stylesheet. Warm paper, decisive
          ink, and a sparse mint-to-violet ramp that only appears where life is
          happening.
        </p>
      </section>

      <h2>Ink &amp; neutrals</h2>
      <SwatchGrid tokens={inks} />

      <h2>Paper &amp; canvas</h2>
      <SwatchGrid tokens={papers} hairline />

      <h2>Accents</h2>
      <SwatchGrid tokens={accents} />

      <h2>Brand ramp</h2>
      <div className='lab-gradient-band' />
      <div className='lab-ramp-label'>
        linear-gradient(92deg, mint 4% → blue 46% → violet 74% → rose 96%) ·
        display text and progress only
      </div>

      <h2>Materials · blur only where layers meet</h2>
      <div className='lab-swatches'>
        <figure className='lab-swatch lab-wide'>
          <div
            className='lab-chip lab-glass'
            style={{ background: 'var(--wui-material)' }}
          />
          <figcaption>
            <span className='lab-name'>Material edge</span>
            <span className='lab-value'>
              rgba(250,251,247,.60) + blur 22 sat 1.7 · bars, sidebar, composer
            </span>
          </figcaption>
        </figure>
        <figure className='lab-swatch lab-wide'>
          <div
            className='lab-chip lab-glass'
            style={{ background: 'var(--wui-material-strong)' }}
          />
          <figcaption>
            <span className='lab-name'>Material strong</span>
            <span className='lab-value'>
              rgba(252,253,250,.88) + blur 22 sat 1.7 · text over busy content
            </span>
          </figcaption>
        </figure>
        <figure className='lab-swatch'>
          <div
            className='lab-chip'
            style={{ background: 'var(--wui-material-border)' }}
          />
          <figcaption>
            <span className='lab-name'>Hairline</span>
            <span className='lab-value'>
              rgba(255,255,255,.65) · panel edges
            </span>
          </figcaption>
        </figure>
      </div>

      <h2>White alpha ramp · on ink surface</h2>
      <div className='lab-ramp lab-on-dark'>
        <div style={{ background: 'rgba(255,255,255,0.08)' }}>
          <span>.08 track</span>
        </div>
        <div style={{ background: 'rgba(255,255,255,0.14)' }}>
          <span>.14 faint</span>
        </div>
        <div style={{ background: 'rgba(255,255,255,0.40)' }}>
          <span>.40 kbd</span>
        </div>
        <div style={{ background: 'rgba(255,255,255,0.55)' }}>
          <span>.55 field</span>
        </div>
        <div style={{ background: 'rgba(255,255,255,0.70)' }}>
          <span>.70 hover</span>
        </div>
        <div style={{ background: 'rgba(255,255,255,0.85)' }}>
          <span>.85 active</span>
        </div>
      </div>
      <div className='lab-ramp-label'>
        rgba(255,255,255,α) · six steps: track / faint fill / kbd / field /
        hover / active
      </div>

      <h2>Border ink ramp · on paper</h2>
      <div className='lab-ramp'>
        <div style={{ background: 'rgba(16,21,28,0.04)' }}>
          <span>.04 wash</span>
        </div>
        <div style={{ background: 'rgba(16,21,28,0.05)' }}>
          <span>.05 divider</span>
        </div>
        <div style={{ background: 'rgba(16,21,28,0.07)' }}>
          <span>.07 border</span>
        </div>
        <div style={{ background: 'rgba(16,21,28,0.09)' }}>
          <span>.09 control</span>
        </div>
        <div style={{ background: 'rgba(16,21,28,0.16)' }}>
          <span>.16 connector</span>
        </div>
        <div style={{ background: 'rgba(16,21,28,0.22)' }}>
          <span>.22 scaffold</span>
        </div>
      </div>
      <div className='lab-ramp-label'>
        rgba(16,21,28,α) · one ink, six alphas: wash / divider / border /
        control / connector / scaffold
      </div>
    </div>
  )
}
