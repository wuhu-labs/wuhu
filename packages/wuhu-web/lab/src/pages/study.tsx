export function StudyPage() {
  return (
    <div className='lab-inner'>
      <section>
        <div className='lab-eyebrow'>Living artifact · Design field notes</div>
        <h1 className='lab-display'>
          The space stays yours.{' '}
          <span className='lab-gradient-text'>
            The chrome knows when to leave.
          </span>
        </h1>
        <p className='lab-lede'>
          A customized artifact should feel{' '}
          <strong>full-bleed and sovereign</strong>. Wuhu stays present as a
          quiet material layer — navigation, context, and conversation floating
          above the work, never carving it into an app-shaped rectangle.
        </p>
      </section>

      <section className='lab-bento' aria-label='Example artifact content'>
        <article className='lab-card lab-w7'>
          <span className='lab-card-label'>Momentum · last 14 days</span>
          <h2>Work is converging</h2>
          <p>Active threads are narrowing toward one product language.</p>
          <div className='lab-chart' aria-hidden='true'>
            <svg viewBox='0 0 600 140' preserveAspectRatio='none'>
              <defs>
                <linearGradient id='fill' x1='0' y1='0' x2='0' y2='1'>
                  <stop offset='0' stopColor='#6d73e6' stopOpacity='.26' />
                  <stop offset='1' stopColor='#6d73e6' stopOpacity='0' />
                </linearGradient>
                <linearGradient id='line' x1='0' y1='0' x2='1' y2='0'>
                  <stop offset='0' stopColor='#54b89a' />
                  <stop offset='.52' stopColor='#5d9ee7' />
                  <stop offset='1' stopColor='#8a68eb' />
                </linearGradient>
              </defs>
              <path
                d='M0 122 C70 118, 75 104, 128 107 S210 85, 265 92 S338 64, 395 71 S475 35, 600 22 L600 140 L0 140 Z'
                fill='url(#fill)'
              />
              <path
                d='M0 122 C70 118, 75 104, 128 107 S210 85, 265 92 S338 64, 395 71 S475 35, 600 22'
                fill='none'
                stroke='url(#line)'
                strokeWidth='3.5'
                strokeLinecap='round'
              />
            </svg>
          </div>
        </article>

        <article className='lab-card lab-w5'>
          <span className='lab-card-label'>Session constellation</span>
          <h2>One thought, four agents</h2>
          <p>Sub-sessions stay visibly related without becoming a table.</p>
          <div className='lab-constellation' aria-hidden='true'>
            <svg preserveAspectRatio='none' viewBox='0 0 100 100'>
              <path
                d='M14 16 L82 12 M14 16 L44 88 M14 16 L74 78'
                stroke='rgba(55,66,77,0.18)'
                strokeWidth='0.6'
                fill='none'
              />
            </svg>
            <div className='lab-node lab-you'>YOU</div>
            <div className='lab-node lab-a1'>A1</div>
            <div className='lab-node lab-a2'>A2</div>
            <div className='lab-node lab-a3'>A3</div>
          </div>
        </article>

        <article className='lab-card lab-w4 lab-dark'>
          <span className='lab-card-label'>Ship v0</span>
          <h2>72% of the way there</h2>
          <p>Six open decisions. Three are waiting on this design pass.</p>
          <div className='lab-progress' aria-hidden='true' />
        </article>

        <article className='lab-card lab-w4'>
          <span className='lab-card-label'>Today</span>
          <h2>Make the frame disappear</h2>
          <p>
            Keep system context available without shrinking the artifact into an
            app-shaped rectangle.
          </p>
        </article>

        <article className='lab-card lab-w4'>
          <span className='lab-card-label'>Material rule</span>
          <h2>Blur only where layers meet</h2>
          <p>
            Translucency belongs to chrome. Content surfaces stay crisp, opaque,
            and authored.
          </p>
        </article>
      </section>
    </div>
  )
}
