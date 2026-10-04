import { chromium } from 'playwright-core'
import fs from 'node:fs/promises'
const root = process.env.PROOF_ROOT ?? '/tmp/wuhu105-proof'
await fs.mkdir(`${root}/captures`, { recursive: true })
const browser = await chromium.launch({ channel: 'chrome', headless: true })
try {
  const message = (n) => ({
    n,
    messageId: `message-${n}`,
    conversationId: 'history-proof',
    kind: 'message',
    sender: n % 2 ? 'you' : 'helper',
    senderHandle: n % 2 ? 'You' : 'Helper',
    senderKind: n % 2 ? 'user' : 'session',
    senderTimezone: 'UTC',
    text:
      `Message ${n} — A bounded history fixture. Keep the visible row and its offset while older content loads and the live tail grows.`,
    createdAt: 1780000000 + n,
  })
  const entry = (position) => ({
    position,
    item: position % 2 === 0
      ? {
        direct: {
          _0: {
            id: `input-${position}`,
            timestamp: 800000000 + position,
            sender: { id: 'you', timeZone: 'UTC' },
            content: {
              text:
                `Input ${position}: review this fixture and keep my reading position.`,
            },
          },
        },
      }
      : {
        assistant: {
          _0: {
            id: `assistant-${position}`,
            timestamp: 800000000 + position,
            content: [{
              text: {
                text:
                  `Response ${position} — This recent committed entry is visible without replaying all preceding history. Older records arrive only when requested.`,
              },
            }],
            stopReason: 'end_turn',
            usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
          },
        },
      },
  })
  const requests = []
  let mode = 'normal', pending = null, exhausted = false, preparingUntil = 0
  async function fixture(port, width = 1440, height = 1000) {
    const context = await browser.newContext({
      ignoreHTTPSErrors: true,
      viewport: { width, height },
      colorScheme: 'light',
      reducedMotion: 'reduce',
    })
    await context.addInitScript(() => {
      localStorage.setItem('wuhu.ai-sharing', 'allowed')
      const original = window.fetch.bind(window)
      window.__streams = {}
      window.fetch = async (input, init) => {
        const url = String(input), path = new URL(url, location.origin)
        if (
          path.pathname.includes('/observe') ||
          path.pathname.endsWith('/direct')
        ) {
          const body = new ReadableStream({
            start(controller) {
              window.__streams[path.pathname] = controller
              const sql = path.searchParams.get('sql') || ''
              const encode = (value) =>
                new TextEncoder().encode(`data: ${JSON.stringify(value)}\n\n`)
              if (sql.includes('FROM sessions')) {
                controller.enqueue(encode({
                  columns: [],
                  rows: [[
                    'transcript-proof',
                    'Transcript proof',
                    'idle',
                    'idle',
                    'live',
                    'task',
                    null,
                    0,
                    'kernel',
                    '{"provider":"fixture","model":"test"}',
                    '2026-10-04T16:00:00Z',
                    null,
                    'you',
                  ]],
                }))
              } else if (sql) {
                controller.enqueue(encode({ columns: [], rows: [] }))
              }
              if (
                path.pathname.endsWith('/direct') &&
                !path.searchParams.has('paged')
              ) {
                controller.enqueue(encode({ kind: 'reset', generation: 1 }))
                for (let position = 200; position < 220; position++) {
                  controller.enqueue(encode({
                    kind: 'item',
                    generation: 1,
                    position,
                    item: {
                      assistant: {
                        _0: {
                          id: `assistant-${position}`,
                          timestamp: 800000000 + position,
                          content: [{
                            text: {
                              text:
                                `Response ${position} — baseline transcript fixture.`,
                            },
                          }],
                          stopReason: 'end_turn',
                          usage: {
                            input_tokens: 1,
                            output_tokens: 1,
                            total_tokens: 2,
                          },
                        },
                      },
                    },
                  }))
                }
              }
              if (
                path.pathname.includes('/conversation/') &&
                !path.pathname.includes('/direct')
              ) {
                const after = Number(path.searchParams.get('after'))
                if (after === 0) {
                  for (let n = 100; n < 120; n++) {
                    controller.enqueue(encode({
                      n,
                      messageId: `message-${n}`,
                      conversationId: 'history-proof',
                      kind: 'message',
                      sender: n % 2 ? 'you' : 'helper',
                      senderHandle: n % 2 ? 'You' : 'Helper',
                      senderKind: n % 2 ? 'user' : 'session',
                      senderTimezone: 'UTC',
                      text:
                        `Message ${n} — A bounded history fixture. Keep the visible row and its offset while older content loads and the live tail grows.`,
                      createdAt: 1780000000 + n,
                    }))
                  }
                }
              }
              init?.signal?.addEventListener('abort', () => {
                try {
                  controller.close()
                } catch {}
              })
            },
          })
          return new Response(body, {
            headers: { 'content-type': 'text/event-stream' },
          })
        }
        return original(input, init)
      }
    })
    const page = await context.newPage()
    page.on('pageerror', (e) => console.log('PAGEERROR', e.message))
    await page.route('**/v1/**', async (route) => {
      const url = new URL(route.request().url()), path = url.pathname
      const json = (body) =>
        route.fulfill({
          contentType: 'application/json',
          body: JSON.stringify(body),
        })
      if (path === '/v1/server') {
        return json({
          space: 'Partial loading proof',
          contentBase: null,
          features: ['groups'],
          group: 'shared',
        })
      }
      if (path === '/v1/groups') {
        return json([{ id: 'shared', member: true, readable: true }])
      }
      if (path === '/v1/users') return json({ users: [] })
      if (path === '/v1/conversations') {
        return json({
          conversations: [{ id: 'history-proof', kind: 'users', members: [] }],
        })
      }
      if (path === '/v1/ls' || path === '/v1/list' || path === '/v1/tools/ls') {
        return json({ entries: [], rev: 0 })
      }
      if (path === '/v1/watermark') return json({})
      if (path.endsWith('/messages')) {
        requests.push(url.search)
        const before = url.searchParams.get('before')
        if (before && mode === 'loading') {
          await new Promise((resolve) => {
            pending = resolve
          })
        }
        if (before && mode === 'retry') {
          return route.fulfill({
            status: 500,
            contentType: 'application/json',
            body: JSON.stringify({
              code: 'fixtureFailure',
              message: 'Could not load older history',
            }),
          })
        }
        const start = before ? Number(before) - 20 : 100,
          end = before ? Number(before) - 1 : 119
        return json({
          messages: Array.from({ length: 20 }, (_, i) => message(start + i)),
          before: start,
          hasEarlier: !exhausted,
          headPosition: 119,
        })
      }
      if (path.endsWith('/transcript/page')) {
        if (Date.now() < preparingUntil) {
          return route.fulfill({
            status: 503,
            contentType: 'application/json',
            body: JSON.stringify({
              code: 'transcriptPreparing',
              message: 'Preparing history',
            }),
          })
        }
        if (url.searchParams.has('before') && mode === 'retry') {
          return route.fulfill({
            status: 500,
            contentType: 'application/json',
            body: JSON.stringify({
              code: 'fixtureFailure',
              message: 'Could not load older history',
            }),
          })
        }
        const before = url.searchParams.get('before')
        requests.push(url.search)
        if (mode === 'preparing') {
          mode = 'normal'
          return route.fulfill({
            status: 503,
            contentType: 'application/json',
            body: JSON.stringify({
              code: 'transcriptPreparing',
              message: 'Preparing history',
            }),
          })
        }
        if (before && mode === 'loading') {
          await new Promise((resolve) => {
            pending = resolve
          })
        }
        const start = before ? Number(before) - 20 : 200,
          end = before ? Number(before) - 1 : 219
        return json({
          generation: 1,
          entries: Array.from({ length: 20 }, (_, i) => entry(start + i)),
          origins: [],
          before: start,
          hasEarlier: !exhausted,
          headPosition: 219,
        })
      }
      return json({})
    })
    return { page, context, url: `https://localhost:${port}` }
  }
  const canvas = (page) => page.locator('.wui-canvas')
  async function top(page) {
    await page.waitForTimeout(500)
    await canvas(page).evaluate((e) => {
      e.scrollTop = 0
      e.dispatchEvent(new Event('scroll'))
    })
    await page.waitForTimeout(150)
  }
  async function capture(page, name) {
    await page.screenshot({ path: `${root}/captures/${name}.png` })
  }
  async function latestAnchor(page) {
    return page.evaluate(() => {
      const canvas = document.querySelector('.wui-canvas')
      const top = canvas.getBoundingClientRect().top
      const row = [...canvas.querySelectorAll('[data-history-id]')].find(
        (row) => row.getBoundingClientRect().bottom > top,
      )
      return row
        ? { id: row.dataset.historyId, top: row.getBoundingClientRect().top }
        : null
    })
  }
  async function anchorById(page, id) {
    return page.evaluate(
      (id) =>
        [...document.querySelectorAll('[data-history-id]')].find((e) =>
          e.dataset.historyId === id
        )?.getBoundingClientRect().top,
      id,
    )
  }
  const baseline = await fixture(Number(process.env.BASELINE_PORT ?? 5571))
  await baseline.page.goto(`${baseline.url}/_/conversations/history-proof`, {
    waitUntil: 'load',
  })
  await baseline.page.getByText('Message 119 —', { exact: false }).waitFor()
  await top(baseline.page)
  await capture(baseline.page, 'baseline-desktop-conversation')
  await baseline.page.setViewportSize({ width: 390, height: 844 })
  await baseline.page.waitForTimeout(300)
  await capture(baseline.page, 'baseline-compact-conversation')
  await baseline.page.goto(
    `${baseline.url}/_/sessions/transcript-proof?view=transcript`,
    { waitUntil: 'load' },
  )
  await baseline.page.getByText('Response 219 —', { exact: false }).waitFor()
  await top(baseline.page)
  await capture(baseline.page, 'baseline-compact-transcript')
  await baseline.page.setViewportSize({ width: 1440, height: 1000 })
  await top(baseline.page)
  await capture(baseline.page, 'baseline-desktop-transcript')
  await baseline.context.close()
  const f = await fixture(Number(process.env.CURRENT_PORT ?? 5572))
  await f.page.goto(`${f.url}/_/conversations/history-proof`, {
    waitUntil: 'load',
  })
  if (
    await f.page.evaluate(() =>
      performance.getEntriesByType('navigation')[0].nextHopProtocol
    ) !== 'h2'
  ) throw new Error('expected TLS h2')
  await f.page.getByText('Message 119 —', { exact: false }).waitFor()
  await top(f.page)
  const count = requests.length
  await f.page.waitForTimeout(400)
  if (requests.length !== count) {
    throw new Error('no-interaction autoload cascade')
  }
  await capture(f.page, 'desktop-load-older')
  let a = await latestAnchor(f.page)
  console.log('LOADING ANCHOR', a)
  console.log('ANCHOR BEFORE', a)
  mode = 'loading'
  await f.page.getByRole('button', { name: '↑ Load older', exact: true })
    .click()
  await f.page.getByRole('status').filter({ hasText: 'Loading…' }).waitFor()
  await capture(f.page, 'desktop-loading')
  a = await latestAnchor(f.page)
  console.log('LOADING ANCHOR', a)
  await f.page.evaluate(
    (message) =>
      window.__streams['/v1/conversation/history-proof/observe'].enqueue(
        new TextEncoder().encode(`data: ${JSON.stringify(message)}\n\n`),
      ),
    message(120),
  )
  const afterAppend = await anchorById(f.page, a.id)
  if (Math.abs(afterAppend - a.top) > 1) {
    throw new Error(`append anchor moved ${afterAppend - a.top}`)
  }
  mode = 'normal'
  pending()
  pending = null
  await f.page.getByText('Message 80 —', { exact: false }).waitFor()
  const b = await anchorById(f.page, a.id)
  console.log('ANCHOR AFTER', b)
  if (Math.abs(b - a.top) > 1) {
    throw new Error(`prepend anchor moved ${b - a.top}`)
  }
  await capture(f.page, 'desktop-prepend-live-anchor')
  await f.page.evaluate(() => {
    const earlier = document.querySelector('[data-history-id=message-90]')
    const late = document.createElement('div')
    late.style.height = '120px'
    earlier.append(late)
  })
  await f.page.waitForTimeout(100)
  const delayed = await anchorById(f.page, a.id)
  if (Math.abs(delayed - a.top) > 1) {
    throw new Error(`delayed measure anchor moved ${delayed - a.top}`)
  }
  console.log('DELAYED ANCHOR', delayed)
  await top(f.page)
  mode = 'retry'
  await f.page.getByRole('button', { name: '↑ Load older', exact: true })
    .click()
  await f.page.getByRole('button', { name: 'Retry loading history' }).waitFor()
  await capture(f.page, 'desktop-retry')
  mode = 'normal'
  exhausted = true
  await f.page.getByRole('button', { name: 'Retry loading history' }).click()
  await f.page.getByText('Beginning of history', { exact: true }).waitFor()
  await top(f.page)
  await capture(f.page, 'desktop-exhausted')
  await f.page.setViewportSize({ width: 390, height: 844 })
  await f.page.waitForTimeout(300)
  await top(f.page)
  await capture(f.page, 'compact-exhausted')
  await f.context.close()
  exhausted = false
  mode = 'normal'
  const narrow = await fixture(
    Number(process.env.CURRENT_PORT ?? 5572),
    390,
    844,
  )
  await narrow.page.goto(`${narrow.url}/_/conversations/history-proof`, {
    waitUntil: 'load',
  })
  await narrow.page.getByText('Message 119 —', { exact: false }).waitFor()
  await top(narrow.page)
  await capture(narrow.page, 'compact-load-older')
  mode = 'loading'
  await narrow.page.getByRole('button', { name: '↑ Load older', exact: true })
    .click()
  await narrow.page.getByText('Loading…', { exact: true }).waitFor()
  await capture(narrow.page, 'compact-loading')
  const compactAnchor = await latestAnchor(narrow.page)
  mode = 'normal'
  pending()
  await narrow.page.getByText('Message 80 —', { exact: false }).waitFor()
  const compactAfter = await anchorById(narrow.page, compactAnchor.id)
  if (Math.abs(compactAfter - compactAnchor.top) > 1) {
    throw new Error(
      `compact prepend anchor moved ${compactAfter - compactAnchor.top}`,
    )
  }
  console.log('COMPACT ANCHOR', compactAnchor, compactAfter)
  await top(narrow.page)
  mode = 'retry'
  await narrow.page.getByRole('button', { name: '↑ Load older', exact: true })
    .click()
  await narrow.page.getByRole('button', { name: 'Retry loading history' })
    .waitFor()
  await capture(narrow.page, 'compact-retry')
  await narrow.context.close()
  mode = 'normal'
  const t = await fixture(Number(process.env.CURRENT_PORT ?? 5572))
  await t.page.goto(`${t.url}/_/sessions/transcript-proof?view=transcript`, {
    waitUntil: 'load',
  })
  await t.page.getByText('Response 219 —', { exact: false }).waitFor()
  await top(t.page)
  await capture(t.page, 'desktop-transcript-load-older')
  const ta = await latestAnchor(t.page)
  mode = 'loading'
  await t.page.getByRole('button', { name: '↑ Load older', exact: true })
    .click()
  await t.page.getByText('Loading…', { exact: true }).waitFor()
  await capture(t.page, 'desktop-transcript-loading')
  mode = 'normal'
  pending()
  await t.page.getByText('Input 180:', { exact: false }).waitFor()
  const tb = await anchorById(t.page, ta.id)
  console.log('TRANSCRIPT ANCHOR', ta, tb)
  if (Math.abs(tb - ta.top) > 1) {
    throw new Error(`transcript prepend anchor moved ${tb - ta.top}`)
  }
  await capture(t.page, 'desktop-transcript-prepend-anchor')
  await t.page.setViewportSize({ width: 390, height: 844 })
  await top(t.page)
  await capture(t.page, 'compact-transcript-load-older')
  mode = 'loading'
  await t.page.getByRole('button', { name: '↑ Load older', exact: true })
    .click()
  await t.page.getByText('Loading…', { exact: true }).waitFor()
  await capture(t.page, 'compact-transcript-loading')
  const compactTranscript = await latestAnchor(t.page)
  mode = 'normal'
  pending()
  await t.page.getByText('Input 160:', { exact: false }).waitFor()
  const compactTranscriptAfter = await anchorById(t.page, compactTranscript.id)
  if (Math.abs(compactTranscriptAfter - compactTranscript.top) > 1) {
    throw new Error(
      `compact transcript anchor moved ${
        compactTranscriptAfter - compactTranscript.top
      }`,
    )
  }
  console.log(
    'COMPACT TRANSCRIPT ANCHOR',
    compactTranscript,
    compactTranscriptAfter,
  )
  await top(t.page)
  mode = 'retry'
  await t.page.getByRole('button', { name: '↑ Load older', exact: true })
    .click()
  await t.page.getByRole('button', { name: 'Retry loading history' }).waitFor()
  await capture(t.page, 'compact-transcript-retry')
  mode = 'normal'
  exhausted = true
  await t.page.getByRole('button', { name: 'Retry loading history' }).press(
    'Enter',
  )
  await t.page.getByText('Beginning of history', { exact: true }).waitFor()
  await top(t.page)
  await capture(t.page, 'compact-transcript-exhausted')
  await t.page.setViewportSize({ width: 1440, height: 1000 })
  await top(t.page)
  await capture(t.page, 'desktop-transcript-exhausted')
  await t.context.close()
  exhausted = false
  preparingUntil = Date.now() + 1500
  const prep = await fixture(Number(process.env.CURRENT_PORT ?? 5572), 390, 844)
  await prep.page.goto(
    `${prep.url}/_/sessions/transcript-proof?view=transcript`,
    { waitUntil: 'load' },
  )
  await prep.page.getByText('Preparing history…', { exact: true })
    .waitFor()
  await capture(prep.page, 'compact-transcript-preparing')
  preparingUntil = 0
  await prep.page.getByText('Response 219 —', { exact: false }).waitFor()
  await prep.context.close()
  const reference = await browser.newPage({
    viewport: { width: 1120, height: 760 },
  })
  await reference.goto(`file://${root}/reference.svg`, { waitUntil: 'load' })
  await capture(reference, 'reference-surfaces')
  await reference.close()
  await fs.writeFile(
    `${root}/captures/proof.json`,
    JSON.stringify(
      {
        requests,
        messageAnchor: { before: a, after: b, delayed },
        compactMessageAnchor: { before: compactAnchor, after: compactAfter },
        compactTranscriptAnchor: {
          before: compactTranscript,
          after: compactTranscriptAfter,
        },
        transcriptAnchor: { before: ta, after: tb },
      },
      null,
      2,
    ),
  )
  await browser.close()
  console.log('PROOF PASS')
} finally {
  await browser.close()
}
