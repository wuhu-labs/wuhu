import { chromium } from 'playwright-core'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'

const root = process.env.PROOF_ROOT ?? '/tmp/wuhu106-proof'
const port = Number(process.env.PROOF_PORT ?? 5573)
const fixtures = JSON.parse(
  await fs.readFile(
    process.env.SEMANTIC_FIXTURES ?? `${root}/transcript-semantics.json`,
    'utf8',
  ),
).fixtures
const get = (name) =>
  structuredClone(fixtures.find((fixture) => fixture.name === name))
await fs.mkdir(`${root}/captures`, { recursive: true })
const browser = await chromium.launch({ channel: 'chrome', headless: true })
const assertions = [], errors = [], serviceWorkerWarnings = [], requests = []
function entries(events) {
  const items = new Map()
  for (const event of events) {
    if (event.kind === 'stream') continue
    const position = event.position,
      common = { id: `entry-${position}`, timestamp: 800000000 + position }
    const content = { text: event.text ?? '' }
    let item
    switch (event.kind) {
      case 'input':
        item = {
          direct: {
            _0: { ...common, sender: { id: 'you', timeZone: 'UTC' }, content },
          },
        }
        break
      case 'notice':
        item = {
          notification: {
            _0: {
              ...common,
              kind: event.noticeKind ?? 'context',
              subscriptionID: 'fixture',
              endsSubscription: false,
              conversations: [],
              content,
            },
          },
        }
        break
      case 'bookmark':
        item = { bookmark: { _0: { ...common, name: event.text ?? null } } }
        break
      case 'result':
        item = {
          toolResult: {
            _0: {
              ...common,
              provenance: { toolCall: { _0: event.callID } },
              payload: {
                [event.failed ? 'failure' : 'success']: { _0: event.output },
              },
            },
          },
        }
        break
      default: {
        const blocks = items.get(position)?.assistant?._0.content ?? []
        blocks[event.part] = event.kind === 'reasoning'
          ? { reasoning: { summary: event.text ?? '', redacted: false } }
          : event.kind === 'text'
          ? { text: content }
          : {
            tool_call: {
              id: event.callID,
              name: event.name,
              arguments: JSON.stringify(event.arguments ?? {}),
            },
          }
        item = {
          assistant: {
            _0: {
              ...common,
              content: blocks,
              stopReason: events.some((e) =>
                  e.position === position && ['tool', 'send'].includes(e.kind)
                )
                ? 'tool_use'
                : 'end_turn',
              usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
            },
          },
        }
      }
    }
    items.set(position, item)
  }
  return [...items].map(([position, item]) => ({ position, item }))
}
async function openFixture(
  fixture,
  width = 1440,
  height = 1000,
  earlier = [],
  options = {},
) {
  let releaseOlder
  const olderGate = options.delayOlder
    ? new Promise((resolve) => {
      releaseOlder = resolve
    })
    : Promise.resolve()
  let older = entries(earlier)
  let loaded = entries(fixture.events),
    generation = fixture.events.find((e) => e.generation != null)?.generation ??
      7
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
    viewport: { width, height },
    colorScheme: 'light',
    reducedMotion: 'reduce',
  })
  await context.addInitScript(({ working }) => {
    localStorage.setItem('wuhu.ai-sharing', 'allowed')
    const original = window.fetch.bind(window)
    window.__streams = {}
    window.__directConnections = 0
    window.fetch = async (input, init) => {
      const path = new URL(String(input), location.origin)
      if (
        path.pathname.includes('/observe') || path.pathname.endsWith('/direct')
      ) {
        const body = new ReadableStream({
          start(controller) {
            window.__streams[path.pathname] = controller
            if (path.pathname.endsWith('/direct')) window.__directConnections++
            const sql = path.searchParams.get('sql') ?? ''
            const encode = (value) =>
              new TextEncoder().encode(`data: ${JSON.stringify(value)}\n\n`)
            if (sql.includes('FROM sessions')) {
              controller.enqueue(encode({
                columns: [],
                rows: [[
                  'transcript-proof',
                  'Transcript proof',
                  'idle',
                  working ? 'has_work' : 'idle',
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
  }, { working: fixture.working })
  const page = await context.newPage()
  page.on('pageerror', (e) => {
    if (
      e.message.startsWith('Failed to register a ServiceWorker') &&
      e.message.includes(`https://localhost:${port}/_/service-worker.js`)
    ) serviceWorkerWarnings.push(e.message)
    else errors.push(e.message)
  })
  await page.route('**/v1/**', async (route) => {
    const url = new URL(route.request().url()), path = url.pathname
    const json = (body) =>
      route.fulfill({
        contentType: 'application/json',
        body: JSON.stringify(body),
      })
    if (path === '/v1/server') {
      return json({
        space: 'Transcript proof',
        contentBase: null,
        features: ['groups'],
        group: 'shared',
      })
    }
    if (path === '/v1/groups') {
      return json([{ id: 'shared', member: true, readable: true }])
    }
    if (path === '/v1/users') return json({ users: [] })
    if (path === '/v1/conversations') return json({ conversations: [] })
    if (['/v1/ls', '/v1/list', '/v1/tools/ls'].includes(path)) {
      return json({ entries: [], rev: 0 })
    }
    if (path.endsWith('/transcript/page')) {
      requests.push(url.search)
      if (url.searchParams.has('before')) await olderGate
      const pageEntries = url.searchParams.has('before')
        ? older.splice(0)
        : loaded
      return json({
        generation,
        entries: pageEntries,
        origins: options.origins ?? [],
        before: pageEntries[0]?.position ?? null,
        hasEarlier: older.length > 0,
        headPosition: loaded.at(-1)?.position ?? -1,
      })
    }
    return json({})
  })
  await page.goto(
    `https://localhost:${port}/_/sessions/transcript-proof?view=transcript`,
    { waitUntil: 'load' },
  )
  await page.locator('.wuhu-turns').waitFor()
  await page.waitForFunction(() =>
    !!window.__streams['/v1/session/transcript-proof/direct']
  )
  assert.equal(
    await page.evaluate(() =>
      performance.getEntriesByType('navigation')[0].nextHopProtocol
    ),
    'h2',
  )
  const emit = async (event) =>
    page.evaluate(
      (event) =>
        window.__streams['/v1/session/transcript-proof/direct'].enqueue(
          new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`),
        ),
      event,
    )
  const append = async (event, gen = generation) => {
    loaded.push(event)
    await emit({ kind: 'item', generation: gen, ...event })
  }
  const top = async () => {
    await page.locator('.wui-canvas').evaluate((canvas) => {
      canvas.scrollTop = 0
      canvas.dispatchEvent(new Event('scroll'))
    })
  }
  const capture = async (name) => {
    if (
      [
        'mixed-history',
        'back-to-history',
        'long-history',
        'live-update-reading-history',
        'history-large-text',
      ].includes(name)
    ) {
      assert.equal(
        await page.locator('.wuhu-inspector').evaluate((dialog) => dialog.open),
        true,
      )
    }
    if (name === 'timeline-large-text') {
      assert.equal(
        await page.locator('.wuhu-inspector').evaluate((dialog) => dialog.open),
        false,
      )
      if (width < 500) {
        assert.equal(
          await page.locator('.wui-root').evaluate((el) =>
            el.classList.contains('wui-mode-focus')
          ),
          true,
        )
      }
    }

    await page.screenshot({
      path: `${root}/captures/${width < 500 ? 'narrow' : 'wide'}-${name}.png`,
    })
  }
  return {
    page,
    context,
    emit,
    append,
    capture,
    top,
    releaseOlder,
    reset: (nextGeneration) => {
      generation = nextGeneration
      loaded = []
    },
  }
}
try {
  for (const width of [1440, 390]) {
    const declared = get('latest-batch-declared')
    const f = await openFixture(
      { ...declared, events: declared.events.slice(0, 1) },
      width,
      width === 390 ? 844 : 1000,
    )
    const batch = entries(declared.events).at(-1)
    await f.emit({ kind: 'started', attemptId: 'active' })
    await f.emit({
      kind: 'materialized',
      attemptId: 'active',
      entryId: batch.item.assistant._0.id,
    })
    await f.append(batch)
    await f.page.locator('.wuhu-turn-tool').last().waitFor()
    assert.deepEqual(
      await f.page.locator('.wuhu-turn-tool-state').allTextContents(),
      ['Running', 'Queued'],
    )
    await f.top()
    await f.capture('active-sequential-batch')
    await f.append(entries(get('first-result').events).at(-1))
    await f.page.getByText('Done', { exact: true }).waitFor()
    assert.deepEqual(
      await f.page.locator('.wuhu-turn-tool-state').allTextContents(),
      ['Done', 'Running'],
    )
    await f.capture('first-result-advances-executor')
    await f.emit({
      kind: 'cancelled',
      attemptId: 'active',
      reason: 'interrupted',
    })
    await f.page.getByText('Unknown', { exact: true }).waitFor()
    assert.deepEqual(
      await f.page.locator('.wuhu-turn-tool-state').allTextContents(),
      ['Done', 'Unknown'],
    )
    await f.capture('cancelled-truthful-pending')
    await f.context.close()
    assertions.push(
      `${width}: materialized Running/Queued -> Done/Running -> cancelled Unknown`,
    )
  }
  for (const width of [1440, 390]) {
    const fixture = await openFixture(
      get('all-results-still-exposed'),
      width,
      width === 390 ? 844 : 1000,
    )
    const { page, emit, append, capture, top } = fixture
    await page.locator('.wuhu-turn-tool-state').last().waitFor()
    assert.deepEqual(
      await page.locator('.wuhu-turn-tool-state').allTextContents(),
      ['Done', 'Done'],
    )
    assert.equal(await page.locator('.wuhu-turn-summary').count(), 0)
    assert.equal(await page.getByText('Preamble', { exact: true }).count(), 1)
    await top()
    await capture('latest-all-results')
    await emit({ kind: 'started', attemptId: 'next' })
    await emit({
      kind: 'delta',
      attemptId: 'next',
      text: 'A speculative next answer',
    })
    await page.getByText('A speculative next answer', { exact: true }).waitFor()
    assert.equal(await page.locator('.wuhu-turn-tool').count(), 2)
    assert.equal(await page.locator('.wuhu-turn-summary').count(), 0)
    await capture('transient-does-not-fold')
    const notice = entries(get('notice-does-not-fold').events).at(-1)
    await append(notice)
    await page.getByText('Instructions loaded', { exact: true }).waitFor()
    await capture('context-latest')
    const answer = entries(get('next-committed-folds').events).at(-1)
    await emit({
      kind: 'materialized',
      attemptId: 'next',
      entryId: answer.item.assistant._0.id,
    })
    await append(answer)
    await page.locator('.wuhu-turn-summary').waitFor()
    assert.equal(await page.locator('.wuhu-turn-tool').count(), 0)
    await top()
    await capture('next-inference-fold')
    const trigger = page.locator('.wuhu-turn-summary')
    await trigger.focus()
    await page.keyboard.press('Enter')
    await page.getByRole('dialog', { name: 'Work history' }).waitFor()
    assert.deepEqual(
      await page.locator('.wuhu-history-row strong').allTextContents(),
      ['Reasoning', 'Preamble', 'read', 'grep', 'Instructions loaded'],
    )
    await capture('mixed-history')
    await page.locator('.wuhu-history-row').nth(2).click()
    await page.getByRole('dialog', { name: 'read', exact: true }).waitFor()
    assert.match(
      await page.locator('.wuhu-inspector-body').innerText(),
      /Plan body/,
    )
    assert.equal(
      await page.getByRole('button', { name: 'Back to work history' }).count(),
      1,
    )
    assert.ok(await page.locator('[data-wuhu-copy]').count() >= 2)
    const closeTarget = await page.getByRole('button', {
      name: 'Close',
      exact: true,
    }).boundingBox()
    assert.ok(closeTarget.width >= 44 && closeTarget.height >= 44)
    await capture('tool-detail')
    await page.getByRole('button', { name: 'Back to work history' }).click()
    assert.equal(
      await page.evaluate(() => document.activeElement?.dataset.eventId),
      '7:1:2',
    )
    await capture('back-to-history')
    await page.locator('.wuhu-history-row').first().focus()
    await page.keyboard.press('Enter')
    await page.getByRole('dialog', { name: 'Reasoning', exact: true }).waitFor()
    assert.match(
      await page.locator('.wuhu-inspector-body').innerText(),
      /Inspect first/,
    )
    await capture('reasoning-detail')
    await page.keyboard.press('Escape')
    assert.equal(
      await page.evaluate(() => document.activeElement?.className),
      'wuhu-turn-summary',
    )
    assert.equal(
      await page.evaluate(() =>
        document.documentElement.scrollWidth > innerWidth
      ),
      false,
    )
    assertions.push(
      `${width}: latest/delta/context/next/history/tool/reasoning/back/focus`,
    )
    await fixture.context.close()
  }
  const long = get('next-committed-folds')
  const longBody = Array.from(
    { length: 200 },
    (_, i) =>
      `Source line ${i}: full available text is retained. ${
        'payload '.repeat(8)
      }`,
  ).join('\n')
  long.events[1].text = longBody
  long.events.find((e) => e.kind === 'result').output = longBody
  // Additional old committed inferences make history scrollable without putting payloads into the list.
  const old = Array.from(
    { length: 15 },
    (_, position) => ({
      generation: 7,
      position,
      part: 0,
      kind: 'reasoning',
      text: `Older inference ${position}: ${longBody}`,
    }),
  )
  long.events.forEach((event) => {
    if (event.position != null) event.position += 15
  })
  long.events = [...old, ...long.events.filter((e) => e.kind !== 'input')]
  for (const width of [1440, 390]) {
    const f = await openFixture(long, width, width === 390 ? 844 : 1000)
    const { page, capture, append } = f
    await page.locator('.wuhu-turn-summary').first().click()
    await page.getByRole('dialog', { name: 'Work history' }).waitFor()
    const body = page.locator('.wuhu-inspector-body')
    await body.evaluate((e) => {
      e.scrollTop = 500
    })
    const before = await body.evaluate((e) => e.scrollTop)
    await capture('long-history')
    const rowsBefore = await page.locator('.wuhu-history-row').count()
    await append(
      entries([{
        generation: 7,
        position: 21,
        part: 0,
        kind: 'text',
        text: 'Live update while reading history.',
      }])[0],
    )
    await page.getByText('Live update while reading history.', { exact: true })
      .waitFor({ state: 'attached' })
    assert.equal(await page.locator('.wuhu-history-row').count(), rowsBefore)
    assert.equal(await body.evaluate((e) => e.scrollTop), before)
    await capture('live-update-reading-history')
    const selected = page.locator('.wuhu-history-row').nth(7)
    await selected.click()
    await page.getByRole('button', { name: 'Back to work history' }).waitFor()
    assert.match(await body.innerText(), /Source line 199/)
    await capture('long-detail')
    await page.getByRole('button', { name: 'Back to work history' }).click()
    // Clicking row 7 may scroll it into view; record its list position, drill once more, and verify exact restoration.
    const savedTop = await body.evaluate((e) => e.scrollTop)
    await selected.click()
    await page.getByRole('button', { name: 'Back to work history' }).click()
    assert.equal(await body.evaluate((e) => e.scrollTop), savedTop)
    assert.equal(
      await page.evaluate(() => document.activeElement?.dataset.eventId),
      '7:7:0',
    )
    await page.keyboard.press('Escape')
    await page.waitForFunction(() =>
      !document.querySelector('.wuhu-inspector')?.open
    )
    await page.evaluate(() => {
      document.documentElement.style.fontSize = '24px'
    })
    await page.locator('.wuhu-turn-summary').first().focus()
    await page.keyboard.press('Enter')
    await page.getByRole('dialog', { name: 'Work history' }).waitFor()
    assert.equal(
      await page.evaluate(() =>
        getComputedStyle(document.documentElement).fontSize
      ),
      '24px',
    )
    assert.equal(
      await page.locator('.wuhu-history-row').first().evaluate((e) =>
        getComputedStyle(e).fontSize
      ),
      '18px',
    )
    await capture('history-large-text')
    assert.equal(
      await page.evaluate(() =>
        document.documentElement.scrollWidth > innerWidth
      ),
      false,
    )
    await page.keyboard.press('Escape')
    await page.waitForFunction(() =>
      !document.querySelector('.wuhu-inspector')?.open
    )
    assert.equal(
      await page.locator('.wuhu-turn-summary').first().evaluate((e) =>
        getComputedStyle(e).fontSize
      ),
      '16.5px',
    )
    await capture('timeline-large-text')
    assertions.push(
      `${width}: long/full-body/live-history/scroll-focus/150%-text`,
    )
    await f.context.close()
  }
  const lifecycle = await openFixture(get('next-committed-folds'))
  await lifecycle.page.locator('.wuhu-turn-summary').click()
  await lifecycle.page.locator('.wuhu-history-row').nth(2).click()
  const detailBefore = await lifecycle.page.locator('.wuhu-inspector-body')
    .innerText()
  const requestsBefore = requests.length
  const connectionsBefore = await lifecycle.page.evaluate(() =>
    window.__directConnections
  )
  await lifecycle.page.evaluate(() =>
    window.__streams['/v1/session/transcript-proof/direct'].close()
  )
  await lifecycle.page.waitForFunction(
    (before) => window.__directConnections > before,
    connectionsBefore,
  )
  await lifecycle.page.waitForFunction(() =>
    !document.querySelector('.wuhu-turn-status')?.textContent.includes(
      'Reconnecting',
    )
  )
  assert.equal(
    await lifecycle.page.locator('.wuhu-inspector-body').innerText(),
    detailBefore,
  )
  assert.ok(requests.length > requestsBefore)
  await lifecycle.capture('reconnect-retains-detail')
  lifecycle.reset(8)
  await lifecycle.emit({ kind: 'reset', generation: 8 })
  await lifecycle.page.waitForFunction(() =>
    !document.querySelector('.wuhu-inspector')?.open
  )
  await lifecycle.append(
    entries([{
      generation: 8,
      position: 0,
      part: 0,
      kind: 'text',
      text: 'New generation answer.',
    }])[0],
    8,
  )
  await lifecycle.page.getByText('New generation answer.', { exact: true })
    .waitFor()
  assert.equal(await lifecycle.page.locator('.wuhu-turn-summary').count(), 0)
  await lifecycle.capture('generation-reset-dismisses-detail')
  await lifecycle.context.close()
  assertions.push(
    'reconnect preserves valid detail; generation reset dismisses old detail',
  )

  const prefix = Array.from(
    { length: 60 },
    (_, position) => ({
      generation: 7,
      position,
      part: 0,
      kind: 'text',
      text: `Visible answer ${position}. ${
        'Retained reading content. '.repeat(8)
      }`,
    }),
  )
  const partial = await openFixture(
    { events: prefix.slice(40), working: false },
    390,
    844,
    prefix.slice(0, 40),
  )
  await partial.top()
  const anchor = partial.page.locator('[data-history-id="7:40:0"]')
  const before = await anchor.evaluate((element) =>
    element.getBoundingClientRect().top
  )
  await partial.page.getByRole('button', { name: '↑ Load older', exact: true })
    .click()
  await partial.page.getByText('Visible answer 0.', { exact: false }).waitFor({
    state: 'attached',
  })
  const after = await anchor.evaluate((element) =>
    element.getBoundingClientRect().top
  )
  assert.ok(
    Math.abs(after - before) < 2,
    `prepend moved retained anchor ${before} -> ${after}`,
  )
  assert.equal(
    await partial.page.locator('[data-history-id="7:40:0"]').count(),
    1,
  )
  await partial.capture('partial-prepend-retains-anchor')
  await partial.context.close()
  assertions.push(
    'bounded earlier HTTP page joins without changing retained viewport anchor',
  )

  for (const width of [1440, 390]) {
    const tail = get('receipt-first-tail-with-companion')
    const joined = get('receipt-tail-prepend-folded-declaration')
    tail.events.at(-1).text = 'Answer.\n\n' +
      'Retained output below the reader.\n\n'.repeat(80)
    const declaration = joined.events.filter((e) => e.position === 7)
    const f = await openFixture(
      tail,
      width,
      width === 390 ? 844 : 1000,
      declaration,
      {
        origins: entries(declaration),
      },
    )
    const { page, capture } = f
    await f.top()
    const receipt = page.locator('[data-history-id="7:8:0"]')
    assert.equal(await page.locator('.wuhu-turn-tool').count(), 1)
    assert.equal(await page.locator('.wuhu-turn-summary').count(), 0)
    const before = await receipt.evaluate((e) => e.getBoundingClientRect().top)
    await capture('receipt8-companion-only')
    await page.getByRole('button', { name: '↑ Load older', exact: true })
      .click()
    await page.locator('[data-history-id="summary:7:7:0"]').waitFor()
    const after = await receipt.evaluate((e) => e.getBoundingClientRect().top)
    assert.ok(
      Math.abs(after - before) < 2,
      `receipt join moved anchor ${before} -> ${after}`,
    )
    assert.equal(await receipt.count(), 1)
    assert.equal(
      await receipt.evaluate((e) => e.getBoundingClientRect().height),
      0,
    )
    assert.equal(await page.locator('.wuhu-turn-tool').count(), 0)
    assert.match(await page.locator('.wuhu-turn-summary').innerText(), /1 tool/)
    await capture('receipt8-joined-folded7')
    await page.locator('.wuhu-turn-summary').click()
    assert.deepEqual(
      await page.locator('.wuhu-history-row strong').allTextContents(),
      ['Reasoning', 'read'],
    )
    await page.locator('.wuhu-history-row').last().click()
    assert.match(await page.locator('.wuhu-inspector-body').innerText(), /Plan/)
    await page.keyboard.press('Escape')
    assertions.push(
      `${width}: exact loaded receipt8 companion -> prepend declaration7 folded under latest9; same viewport anchor, zero duplicate rows/counts`,
    )
    await f.context.close()
  }

  const viewportAnchor = (page) =>
    page.locator('.wuhu-inspector-body').evaluate((body) => {
      const top = body.getBoundingClientRect().top
      const visible = [...body.querySelectorAll('[data-event-id]')].find((
        row,
      ) => row.getBoundingClientRect().bottom > top)
      return {
        id: visible.dataset.eventId,
        offset: visible.getBoundingClientRect().top - top,
        scrollTop: body.scrollTop,
      }
    })
  const offsetOf = (page, id) =>
    page.locator(`[data-event-id="${id}"]`).evaluate((row) =>
      row.getBoundingClientRect().top -
      row.closest('.wuhu-inspector-body').getBoundingClientRect().top
    )
  for (const width of [1440, 390]) {
    const old = Array.from({ length: 50 }, (_, position) => ({
      generation: 7,
      position,
      part: 0,
      kind: 'reasoning',
      text: `Reasoning ${position}`,
    }))
    const f = await openFixture(
      {
        events: [...old.slice(20), {
          generation: 7,
          position: 50,
          part: 0,
          kind: 'reasoning',
          text: 'Latest inference remains exposed.',
        }],
        working: false,
      },
      width,
      width === 390 ? 844 : 1000,
      old.slice(0, 20),
      { delayOlder: true },
    )
    const { page, capture } = f
    await f.top()
    await page.getByRole('button', { name: '↑ Load older', exact: true })
      .click()
    await page.getByText('Loading…', { exact: true }).waitFor()
    await page.locator('.wuhu-turn-summary').click()
    await page.getByRole('dialog', { name: 'Work history' }).waitFor()
    const body = page.locator('.wuhu-inspector-body')
    await body.evaluate((e) => {
      e.scrollTop = 500
      e.dispatchEvent(new Event('scroll'))
    })
    const saved = await viewportAnchor(page)
    const selectedID = `7:${Number(saved.id.split(':')[1]) + 1}:0`
    await capture('pending-older-history-position')
    await page.locator(`[data-event-id="${selectedID}"]`).click()
    await page.getByRole('button', { name: 'Back to work history' }).waitFor()
    const detail = await body.innerText()
    f.releaseOlder()
    await page.locator('[data-history-id="summary:7:0:0"]').waitFor({
      state: 'attached',
    })
    assert.equal(await body.innerText(), detail)
    await capture('older-arrives-detail-stays-open')
    await page.getByRole('button', { name: 'Back to work history' }).click()
    assert.equal(await page.locator('.wuhu-history-row').count(), 50)
    assert.equal(
      await page.evaluate(() => document.activeElement?.dataset.eventId),
      selectedID,
    )
    const restored = await offsetOf(page, saved.id)
    assert.ok(
      Math.abs(restored - saved.offset) < 2,
      `Back moved stable history item ${saved.offset} -> ${restored}`,
    )
    const prependedHeight = await page.locator('.wuhu-history-row').evaluateAll(
      (rows) =>
        rows.slice(0, 20).reduce(
          (sum, row) => sum + row.getBoundingClientRect().height,
          0,
        ),
    )
    assert.ok(
      Math.abs(
        (await body.evaluate((e) => e.scrollTop)) - saved.scrollTop -
          prependedHeight,
      ) < 2,
    )
    await capture('back-after-prepend-stable-item-focus')
    await f.append(
      entries([{
        generation: 7,
        position: 51,
        part: 0,
        kind: 'reasoning',
        text: 'New committed inference extends prior work history.',
      }])[0],
    )
    await page.waitForFunction(() =>
      document.querySelectorAll('.wuhu-history-row').length === 51
    )
    const liveOffset = await offsetOf(page, saved.id)
    assert.ok(
      Math.abs(liveOffset - saved.offset) < 2,
      `live history update moved item ${saved.offset} -> ${liveOffset}`,
    )
    await capture('live-history-stable-source-offset')
    await page.keyboard.press('Escape')
    assert.equal(
      await page.evaluate(() => document.activeElement?.className),
      'wuhu-turn-summary',
    )
    assertions.push(
      `${width}: older page pending -> history/detail -> prepend extends segment -> Back restores source pixel offset and selected focus; new committed inference extends live history without moving its source offset`,
    )
    await f.context.close()
    const openHistory = await openFixture(
      {
        events: [...old.slice(20), {
          generation: 7,
          position: 50,
          part: 0,
          kind: 'reasoning',
          text: 'Latest inference.',
        }],
        working: false,
      },
      width,
      width === 390 ? 844 : 1000,
      old.slice(0, 20),
      { delayOlder: true },
    )
    await openHistory.top()
    await openHistory.page.getByRole('button', {
      name: '↑ Load older',
      exact: true,
    }).click()
    await openHistory.page.locator('.wuhu-turn-summary').click()
    await openHistory.page.getByRole('dialog', { name: 'Work history' })
      .waitFor()
    await openHistory.page.locator('.wuhu-inspector-body').evaluate((e) => {
      e.scrollTop = 500
      e.dispatchEvent(new Event('scroll'))
    })
    const activeAnchor = await viewportAnchor(openHistory.page)
    openHistory.releaseOlder()
    await openHistory.page.waitForFunction(() =>
      document.querySelectorAll('.wuhu-history-row').length === 50
    )
    const activeOffset = await offsetOf(openHistory.page, activeAnchor.id)
    assert.ok(
      Math.abs(activeOffset - activeAnchor.offset) < 2,
      `open history prepend moved source ${activeAnchor.offset} -> ${activeOffset}`,
    )
    await openHistory.capture('open-history-prepend-stable-source-offset')
    assertions.push(
      `${width}: pending older page prepends while history remains open, preserving the visible durable item offset`,
    )
    await openHistory.context.close()
  }
  for (
    const name of [
      'bookmark-after-assistant-remains-visible',
      'bookmark-first-partial-tail-remains-visible',
    ]
  ) {
    const f = await openFixture(get(name), 390, 844)
    await f.top()
    await f.page.getByRole('button', { name: /Bookmark/ }).click()
    await f.page.getByRole('dialog', { name: 'Bookmark', exact: true })
      .waitFor()
    await f.capture(name)
    await f.context.close()
  }
  const emptyStream = await openFixture(
    {
      events: [{
        generation: 7,
        position: 1,
        part: 0,
        kind: 'reasoning',
        text: 'Inspect first',
      }],
      working: false,
    },
    390,
    844,
  )
  await emptyStream.emit({ kind: 'started', attemptId: 'new-attempt' })
  await emptyStream.page.locator('.wuhu-turn-working').waitFor()
  assert.equal(await emptyStream.page.locator('.wuhu-turn-summary').count(), 0)
  assert.equal(
    await emptyStream.page.getByText('Reasoning', { exact: true }).count(),
    1,
  )
  await emptyStream.capture('empty-stream-working-no-fold')
  await emptyStream.context.close()
  assertions.push(
    'bookmarks remain visible and inspectable after assistant and at partial edge; empty stream shows Working with global idle without folding committed work',
  )

  const fallback = await openFixture(
    get('malformed-notice-no-parent'),
    390,
    844,
  )
  await fallback.page.getByText('Context updated', { exact: true }).click()
  assert.match(
    await fallback.page.locator('.wuhu-inspector-body').innerText(),
    /from=broken/,
  )
  await fallback.capture('unknown-context-detail')
  await fallback.context.close()
  const sends = await openFixture(get('consecutive-sends-and-trailing-work'))
  assert.equal(await sends.page.locator('.wuhu-turn-bubble').count(), 2)
  assert.equal(await sends.page.locator('.wuhu-turn-summary').count(), 2)
  await sends.top()
  await sends.capture('sends-trailing-work')
  await sends.context.close()
  assert.deepEqual(errors, [])
  const verdict = {
    status: 'PASS',
    assertions,
    requests,
    browserErrors: errors,
    serviceWorkerWarnings,
    screenshots: (await fs.readdir(`${root}/captures`)).filter((name) =>
      name.endsWith('.png')
    ).sort(),
    limitation:
      'Controlled HTTP pages and cancellable SSE through production SPA; HTML goldens are separate CI assertions, not pixel comparisons. Self-signed TLS service-worker warnings are not offline-shell proof.',
  }
  await fs.writeFile(`${root}/proof.json`, JSON.stringify(verdict, null, 2))
  console.log(JSON.stringify(verdict, null, 2))
} finally {
  await browser.close()
}
