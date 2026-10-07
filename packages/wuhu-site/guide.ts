import { Marked, type Tokens } from 'marked'

export const guideSlugs = [
  'what-wuhu-is',
  'running-the-server',
  'people-and-devices',
  'machines',
  'models',
  'your-data',
] as const

type Language = 'en' | 'zh'

function guidePath(language: Language, slug = ''): string {
  const base = `${language === 'zh' ? '/zh' : ''}/docs`
  return !slug || slug === guideSlugs[0] ? base : `${base}/${slug}`
}

const guideSources = (['en', 'zh'] as const).flatMap((language) =>
  guideSlugs.map((slug, index) => ({
    language,
    slug,
    file: `docs/${language}/${index + 1}-${slug}.md`,
  }))
)

export const guideRoutes = guideSources.flatMap((source) => {
  const base = guidePath(source.language)
  const page = { ...source, key: `${base}/${source.slug}`.slice(1) }
  return source.slug === guideSlugs[0]
    ? [{ ...source, key: base.slice(1) }, {
      ...source,
      key: `${base}/index.html`.slice(1),
    }, page]
    : [page]
})

function escapeHTML(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (character) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[
        character
      ]!,
  )
}

function headingID(text: string): string {
  return text.toLowerCase().replace(/<[^>]*>/g, '').replace(
    /[^\p{L}\p{N}\s_-]/gu,
    '',
  )
    .trim().replace(/\s+/g, '-')
}

function rewriteLink(href: string): string {
  if (!href.startsWith('/guide/')) return href
  const match = /^\/guide\/(zh\/)?([1-6])-([a-z-]+)\.md(#[^\s]*)?$/.exec(href)
  if (!match || guideSlugs[Number(match[2]) - 1] !== match[3]) {
    throw new Error(`Unknown guide link: ${href}`)
  }
  return guidePath(match[1] ? 'zh' : 'en', match[3]) + (match[4] ?? '')
}

function markdownBody(source: string): { title: string; body: string } {
  const match = /^---\r?\ntitle: ([^\n]+)\r?\n---\r?\n/.exec(source)
  if (!match) throw new Error('Guide page needs title frontmatter')
  return { title: match[1]!.trim(), body: source.slice(match[0].length) }
}

function renderMarkdown(body: string, language: Language): string {
  const headings = new Map<string, number>()
  const markdown = new Marked({
    gfm: true,
    renderer: {
      heading({ tokens, depth, text }: Tokens.Heading) {
        const base = headingID(text)
        const count = headings.get(base) ?? 0
        headings.set(base, count + 1)
        const id = count ? `${base}-${count}` : base
        return `<h${depth} id="${escapeHTML(id)}">${
          this.parser.parseInline(tokens)
        }</h${depth}>\n`
      },
      link({ href, title, tokens }: Tokens.Link) {
        return `<a href="${escapeHTML(rewriteLink(href))}"${
          title ? ` title="${escapeHTML(title)}"` : ''
        }>${this.parser.parseInline(tokens)}</a>`
      },
      code({ text, lang }: Tokens.Code) {
        const label = language === 'zh' ? '复制' : 'Copy'
        return `<div class="code-block"><div class="code-bar"><span>${
          escapeHTML(lang ?? 'text')
        }</span><button type="button" class="copy" aria-label="${
          language === 'zh' ? '复制代码' : 'Copy code'
        }">${label}</button></div><pre><code>${
          escapeHTML(text)
        }\n</code></pre></div>\n`
      },
    },
  })
  return markdown.parse(body, { async: false })
}

function pageHTML(
  language: Language,
  slug: string,
  title: string,
  body: string,
  titles: ReadonlyMap<string, string>,
  style: string,
  script: string,
): string {
  const index = guideSlugs.indexOf(slug as typeof guideSlugs[number])
  const link = (page: string, label: string) =>
    `<a href="${guidePath(language, page)}">${escapeHTML(label)}</a>`
  const navigation = guideSlugs.map((page, number) =>
    `<a href="${guidePath(language, page)}"${
      page === slug ? ' aria-current="page"' : ''
    }><span class="page-number">0${number + 1}</span><span>${
      escapeHTML(titles.get(`${language}/${page}`)!)
    }</span></a>`
  ).join('\n')
  const adjacent = (offset: number) => {
    const page = guideSlugs[index + offset]
    return page
      ? link(
        page,
        `${offset < 0 ? '← ' : ''}${titles.get(`${language}/${page}`)}${
          offset > 0 ? ' →' : ''
        }`,
      )
      : '<span></span>'
  }
  return `<!doctype html>
<html lang="${language === 'zh' ? 'zh-CN' : 'en'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${escapeHTML(title)} — wuhu</title>
<link rel="canonical" href="https://wuhu.ai${guidePath(language, slug)}">
<link rel="alternate" hreflang="en" href="https://wuhu.ai${
    guidePath('en', slug)
  }">
<link rel="alternate" hreflang="zh-CN" href="https://wuhu.ai${
    guidePath('zh', slug)
  }">
<style>${style}</style>
</head>
<body>
<a class="skip" href="#content">${
    language === 'zh' ? '跳到正文' : 'Skip to content'
  }</a>
<div class="glow" aria-hidden="true"></div>
<div class="shell">
<header class="site-header">
<a class="mark" href="/">wuhu<span class="pill">${
    language === 'zh' ? '操作指南' : 'operator guide'
  }</span></a>
<nav class="languages" aria-label="${
    language === 'zh' ? '语言' : 'Language'
  }"><a href="${guidePath('en', slug)}" lang="en"${
    language === 'en' ? ' aria-current="true"' : ''
  }>EN</a><span aria-hidden="true">/</span><a href="${
    guidePath('zh', slug)
  }" lang="zh-CN"${
    language === 'zh' ? ' aria-current="true"' : ''
  }>中文</a></nav>
</header>
<div class="layout">
<aside><nav class="pages" aria-label="${
    language === 'zh' ? '指南目录' : 'Guide pages'
  }">${navigation}</nav></aside>
<main id="content" tabindex="-1"><div class="chapter">${
    language === 'zh' ? '指南' : 'THE GUIDE'
  } <span> / 0${
    index + 1
  }</span></div><article>${body}</article><nav class="adjacent" aria-label="${
    language === 'zh' ? '前后章节' : 'Previous and next pages'
  }">${adjacent(-1)}${adjacent(1)}</nav></main>
</div>
<footer><span>© 2026 wuhu</span><a href="/">wuhu.ai ↗</a></footer>
</div>
<script>${script}</script>
</body>
</html>\n`
}

export async function buildGuide(
  siteDirectory = new URL('./', import.meta.url),
): Promise<ReadonlyMap<string, string>> {
  const [style, script, sources] = await Promise.all([
    Deno.readTextFile(new URL('guide.css', siteDirectory)),
    Deno.readTextFile(new URL('guide.js', siteDirectory)),
    Promise.all(guideSources.map(async (page) => ({
      ...page,
      ...markdownBody(
        await Deno.readTextFile(new URL(page.file, siteDirectory)),
      ),
    }))),
  ])
  const titles = new Map(
    sources.map((page) => [`${page.language}/${page.slug}`, page.title]),
  )
  const result = new Map<string, string>()
  for (const page of sources) {
    const html = pageHTML(
      page.language,
      page.slug,
      page.title,
      renderMarkdown(page.body, page.language),
      titles,
      style,
      script,
    )
    for (
      const route of guideRoutes.filter((route) => route.file === page.file)
    ) {
      result.set(route.key, html)
    }
  }
  validateGuideLinks(result)
  return result
}

export function validateGuideLinks(pages: ReadonlyMap<string, string>): void {
  for (const [key, html] of pages) {
    for (
      const match of html.matchAll(
        /href="((?:\/(?:zh\/)?docs(?:\/[^"]*)?|#[^"]*))"/g,
      )
    ) {
      const url = new URL(match[1]!, `https://wuhu.ai/${key}`)
      const target = pages.get(url.pathname.slice(1))
      if (
        !target ||
        (url.hash &&
          !target.includes(
            `id="${escapeHTML(decodeURIComponent(url.hash.slice(1)))}"`,
          ))
      ) {
        throw new Error(`Broken guide link on ${key}: ${match[1]}`)
      }
    }
  }
}
