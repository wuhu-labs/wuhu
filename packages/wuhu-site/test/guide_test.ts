import {
  buildGuide,
  guideRoutes,
  guideSlugs,
  validateGuideLinks,
} from '../guide.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

Deno.test('all twelve pages and canonical landings and index aliases build to self-contained HTML', async () => {
  const pages = await buildGuide()
  assert(pages.size === 16, 'Expected 16 guide keys')
  assert(
    [...pages.keys()].sort().join() ===
      guideRoutes.map((route) => route.key).sort().join(),
    'Guide route set changed',
  )
  for (const language of ['en', 'zh']) {
    const prefix = language === 'zh' ? 'zh/docs' : 'docs'
    assert(
      pages.get(prefix) === pages.get(`${prefix}/what-wuhu-is`),
      'Landing page should be the first page',
    )
    assert(
      pages.get(`${prefix}/index.html`) === pages.get(prefix),
      'Index alias differs from canonical landing',
    )
    assert(!pages.has(`${prefix}/`), 'Trailing-slash object keys must not ship')
    for (const slug of guideSlugs) {
      const html = pages.get(`${prefix}/${slug}`)!
      assert(html.startsWith('<!doctype html>'), 'Not HTML')
      assert(
        html.includes(`<html lang="${language === 'zh' ? 'zh-CN' : 'en'}">`),
        'Wrong language',
      )
      assert(
        html.includes('<style>') && html.includes('<script>'),
        'Assets should be inlined',
      )
      assert(
        !html.includes('src=') && !html.includes('rel="stylesheet"'),
        'Unexpected asset fetch',
      )
      assert(!html.includes('href="/guide/'), 'Space links must not ship')
      assert(
        !html.includes('href="/docs/what-wuhu-is"') &&
          !html.includes('href="/zh/docs/what-wuhu-is"'),
        'First-page links must use canonical landings',
      )
      assert(
        html.includes(
          `href="/${prefix}${
            slug === guideSlugs[0] ? '' : `/${slug}`
          }" aria-current="page"`,
        ),
        'Current page must be marked',
      )
      assert(
        html.includes(
          `href="/docs${slug === guideSlugs[0] ? '' : `/${slug}`}" lang="en"`,
        ),
        'English switch changed the page',
      )
      assert(
        html.includes(
          `href="/zh/docs${
            slug === guideSlugs[0] ? '' : `/${slug}`
          }" lang="zh-CN"`,
        ),
        'Chinese switch changed the page',
      )
      assert(!html.includes('title: '), 'Frontmatter leaked into HTML')
    }
  }
  validateGuideLinks(pages)
})

Deno.test('headings retain EN and Chinese fragment links and cross-page anchors', async () => {
  const pages = await buildGuide()
  const english = pages.get('docs/running-the-server')!
  const chinese = pages.get('zh/docs/running-the-server')!
  assert(
    english.includes('id="picking-a-name"') &&
      english.includes('href="#picking-a-name"'),
    'English anchor broken',
  )
  assert(
    chinese.includes('id="选一个名字"') &&
      chinese.includes('href="#选一个名字"'),
    'Chinese anchor broken',
  )
  assert(
    pages.get('docs/machines')!.includes('href="/docs/models#secrets"'),
    'Cross-page anchor not rewritten',
  )
  assert(
    pages.get('docs/models')!.includes(
      'href="/docs/people-and-devices#groups"',
    ),
    'Groups anchor not rewritten',
  )
})

Deno.test('code renders as escaped text with a localized copy button, without changing commands', async () => {
  const pages = await buildGuide()
  for (
    const [key, label] of [['docs/people-and-devices', 'Copy'], [
      'zh/docs/people-and-devices',
      '复制',
    ]]
  ) {
    const html = pages.get(key)!
    assert(
      html.includes(
        `aria-label="${
          label === 'Copy' ? 'Copy code' : '复制代码'
        }">${label}</button>`,
      ),
      'Copy button missing',
    )
    assert(
      html.includes(
        'wuhu user invite --space &lt;folder&gt; &lt;account-id&gt;\n</code>',
      ),
      'Command text changed or is unescaped',
    )
    assert(
      html.includes('navigator.clipboard.writeText(code)'),
      'Copy control missing',
    )
  }
})

Deno.test('broken page and fragment links fail the build rather than deploying', () => {
  for (const href of ['/docs/missing', '#missing', '/zh/docs/models#不存在']) {
    let failed = false
    try {
      validateGuideLinks(
        new Map([['docs/test', `<a href="${href}">broken</a>`]]),
      )
    } catch {
      failed = true
    }
    assert(failed, `${href} was accepted`)
  }
  validateGuideLinks(
    new Map([
      ['docs/test', '<a href="/zh/docs/models#%E8%AF%81%E4%B9%A6">valid</a>'],
      ['zh/docs/models', '<h2 id="证书">valid</h2>'],
    ]),
  )
})
