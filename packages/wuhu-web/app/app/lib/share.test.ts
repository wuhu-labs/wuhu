import {
  isApplePlatform,
  shareLabel,
  shareLinks,
  sharePage,
  smartBannerContent,
} from './share.ts'

function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

Deno.test('a session page shares its https form and opens its wuhu twin', () => {
  const links = shareLinks(
    'https://space.example:5530',
    '/_/sessions/zebra-forest-bike',
    '',
    '',
  )
  assertEquals(links, {
    https: 'https://space.example:5530/_/sessions/zebra-forest-bike',
    wuhu: 'wuhu://space.example:5530/_/sessions/zebra-forest-bike',
  })
  assertEquals(
    smartBannerContent(links),
    'app-id=6807771419, app-argument=wuhu://space.example:5530/_/sessions/zebra-forest-bike',
  )
})

Deno.test('a file page keeps its query and fragment', () => {
  assertEquals(
    shareLinks('https://box.local', '/notes/My%20Plan.md', '?q=1', '#part')
      ?.https,
    'https://box.local/notes/My%20Plan.md?q=1#part',
  )
})

Deno.test('a place in another group shares its group host', () => {
  assertEquals(
    shareLinks(
      'https://space.example:5530',
      '/notes/plan.md',
      '?group=sail-clock-pepper&q=1',
      '',
    ),
    {
      https: 'https://sail-clock-pepper.space.example:5530/notes/plan.md?q=1',
      wuhu: 'wuhu://sail-clock-pepper.space.example:5530/notes/plan.md?q=1',
    },
  )
})

Deno.test('the SPA screens have no share link', () => {
  assertEquals(shareLinks('https://box.local', '/_/settings', '', ''), null)
  assertEquals(
    shareLinks('https://box.local', '/_/system/AGENTS.md', '', ''),
    null,
  )
  assertEquals(smartBannerContent(null), 'app-id=6807771419')
})

Deno.test('open in app is offered on Apple platforms only', () => {
  assertEquals(
    isApplePlatform(
      'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15',
    ),
    true,
  )
  assertEquals(
    isApplePlatform('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'),
    true,
  )
  assertEquals(
    isApplePlatform('Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0'),
    false,
  )
})

function recordingTarget(share?: (url: string) => Promise<void>) {
  const shared: string[] = []
  const copied: string[] = []
  return {
    shared,
    copied,
    target: {
      ...(share == null ? {} : {
        share: ({ url }: { url: string }) => {
          shared.push(url)
          return share(url)
        },
      }),
      clipboard: {
        writeText: (text: string) => {
          copied.push(text)
          return Promise.resolve()
        },
      },
    },
  }
}

const link = 'https://space.example:5530/_/sessions/zebra-forest-bike'

Deno.test('share hands the https link to the system share sheet', async () => {
  const { shared, copied, target } = recordingTarget(() => Promise.resolve())
  assertEquals(shareLabel(target), 'Share')
  assertEquals(await sharePage(link, target), 'shared')
  assertEquals(shared, [link])
  assertEquals(copied, [])
})

Deno.test('a browser without a share sheet copies the https link', async () => {
  const { copied, target } = recordingTarget()
  assertEquals(shareLabel(target), 'Copy link')
  assertEquals(await sharePage(link, target), 'copied')
  assertEquals(copied, [link])
})

Deno.test('dismissing the share sheet copies nothing', async () => {
  const { copied, target } = recordingTarget(() =>
    Promise.reject(new DOMException('dismissed', 'AbortError'))
  )
  assertEquals(await sharePage(link, target), 'dismissed')
  assertEquals(copied, [])
})

Deno.test('a share sheet that refuses falls back to the clipboard', async () => {
  const { copied, target } = recordingTarget(() =>
    Promise.reject(new DOMException('no gesture', 'NotAllowedError'))
  )
  assertEquals(await sharePage(link, target), 'copied')
  assertEquals(copied, [link])
})
