// install.sh against a local stand-in for wuhu.ai: lane pointers, sidecars and
// a fake `wuhu` packaged for the host platform.

const siteDir = new URL('..', import.meta.url).pathname

function assertEquals<T>(actual: T, expected: T, message = ''): void {
  if (actual !== expected) {
    throw new Error(
      `${message} expected ${JSON.stringify(expected)}, got ${
        JSON.stringify(actual)
      }`,
    )
  }
}

const hostPlatform = (() => {
  if (Deno.build.os === 'darwin' && Deno.build.arch === 'aarch64') {
    return { name: 'macos-arm64', ext: 'zip' }
  }
  if (Deno.build.os === 'linux' && Deno.build.arch === 'x86_64') {
    return { name: 'linux-amd64', ext: 'tar.gz' }
  }
  return undefined
})()

async function sh(
  command: string[],
  options: { cwd?: string; env?: Record<string, string> } = {},
): Promise<{ code: number; stdout: string; stderr: string }> {
  const result = await new Deno.Command(command[0], {
    args: command.slice(1),
    cwd: options.cwd,
    env: { PATH: Deno.env.get('PATH') ?? '/usr/bin:/bin', ...options.env },
    clearEnv: true,
  }).output()
  const decoder = new TextDecoder()
  return {
    code: result.code,
    stdout: decoder.decode(result.stdout),
    stderr: decoder.decode(result.stderr),
  }
}

async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, '0')
  ).join('')
}

interface Release {
  name: string
  bytes: Uint8Array<ArrayBuffer>
  sha256: string
}

async function packageRelease(
  work: string,
  version: string,
): Promise<Release> {
  const platform = hostPlatform!
  const dir = await Deno.makeTempDir({ dir: work })
  await Deno.writeTextFile(
    `${dir}/wuhu`,
    `#!/bin/sh\necho "wuhu ${version} (fake)"\n`,
    { mode: 0o755 },
  )
  const name = `wuhu-${version}-${platform.name}.${platform.ext}`
  const packed = platform.ext === 'zip'
    ? await sh(['zip', '-q', name, 'wuhu'], { cwd: dir })
    : await sh(['tar', '-czf', name, 'wuhu'], { cwd: dir })
  assertEquals(packed.code, 0, `packing ${name}: ${packed.stderr}`)
  const bytes = await Deno.readFile(`${dir}/${name}`)
  return { name, bytes, sha256: await sha256(bytes) }
}

// Serves pointers shaped exactly like tools/release/release-wuhu.ts writes
// them; `tamper` lists artifact names whose served bytes differ from the sha256
// the pointer and the sidecar announce.
function serve(
  lanes: Record<string, { version: string; release: Release }>,
  releases: Release[],
  tamper: Set<string> = new Set(),
): { base: string; close: () => Promise<void> } {
  const server = Deno.serve(
    { hostname: '127.0.0.1', port: 0, onListen: () => {} },
    (request): Response => {
      const path = new URL(request.url).pathname
      const lane = /^\/releases\/([a-z]+)\/latest\.json$/.exec(path)
      if (lane && lanes[lane[1]]) {
        const { version, release } = lanes[lane[1]]
        return Response.json({
          version,
          lane: lane[1],
          artifacts: {
            [hostPlatform!.name]: {
              name: release.name,
              url: `${base}/releases/${release.name}`,
              sha256: release.sha256,
            },
          },
        })
      }
      for (const release of releases) {
        if (path === `/releases/${release.name}`) {
          return new Response(
            tamper.has(release.name)
              ? new Uint8Array([...release.bytes, 0])
              : release.bytes,
          )
        }
        if (path === `/releases/${release.name}.sha256`) {
          return new Response(`${release.sha256}  ${release.name}\n`)
        }
      }
      return new Response('Not Found', { status: 404 })
    },
  )
  const base: string = `http://127.0.0.1:${server.addr.port}`
  return { base, close: () => server.shutdown() }
}

// `current` is the version installed at ~/.wuhu/bin/wuhu, checked to be a
// regular file holding that version's bytes, or null when nothing is there.
async function install(
  base: string,
  env: Record<string, string> = {},
  home?: string,
) {
  home ??= await Deno.makeTempDir()
  const bin = `${home}/.wuhu/bin`
  const result = await sh(['sh', `${siteDir}/install.sh`], {
    env: { HOME: home, WUHU_BASE_URL: base, NO_PROXY: '*', ...env },
  })
  const info = await Deno.lstat(`${bin}/wuhu`).catch(() => null)
  if (info === null) return { ...result, current: null }
  assertEquals(info.isFile, true, 'bin/wuhu is a regular file')
  const current = (await Deno.readTextFile(`${bin}/.current`)).trim()
  const installed = await Deno.readTextFile(`${bin}/wuhu`)
  const source = await Deno.readTextFile(`${bin}/${current}/wuhu`)
  assertEquals(installed, source, 'bin/wuhu holds the .current bytes')
  return { ...result, current }
}

Deno.test({
  name: 'install.sh follows the beta pointer, WUHU_LANE and WUHU_VERSION',
  ignore: hostPlatform === undefined,
  async fn() {
    const work = await Deno.makeTempDir()
    const beta = await packageRelease(work, '0.1.0-beta.7')
    const dev = await packageRelease(work, '0.1.0-dev.30')
    const pinned = await packageRelease(work, '0.1.0-dev.12')
    const site = serve(
      {
        beta: { version: '0.1.0-beta.7', release: beta },
        dev: { version: '0.1.0-dev.30', release: dev },
      },
      [beta, dev, pinned],
    )
    try {
      const byDefault = await install(site.base)
      assertEquals(byDefault.code, 0, byDefault.stderr)
      assertEquals(byDefault.current, '0.1.0-beta.7')
      assertEquals(byDefault.stdout.includes('wuhu 0.1.0-beta.7 (fake)'), true)

      const byLane = await install(site.base, { WUHU_LANE: 'dev' })
      assertEquals(byLane.code, 0, byLane.stderr)
      assertEquals(byLane.current, '0.1.0-dev.30')

      const byVersion = await install(site.base, {
        WUHU_VERSION: '0.1.0-dev.12',
      })
      assertEquals(byVersion.code, 0, byVersion.stderr)
      assertEquals(byVersion.current, '0.1.0-dev.12')

      const home = await Deno.makeTempDir()
      await Deno.mkdir(`${home}/.wuhu/bin/0.1.0-beta.6`, { recursive: true })
      await Deno.writeTextFile(`${home}/.wuhu/bin/0.1.0-beta.6/wuhu`, 'old')
      await Deno.symlink('0.1.0-beta.6/wuhu', `${home}/.wuhu/bin/wuhu`)
      const overSymlink = await install(site.base, {}, home)
      assertEquals(overSymlink.code, 0, overSymlink.stderr)
      assertEquals(overSymlink.current, '0.1.0-beta.7')
      assertEquals(
        await Deno.readTextFile(`${home}/.wuhu/bin/0.1.0-beta.6/wuhu`),
        'old',
      )

      const before = (await Deno.lstat(`${home}/.wuhu/bin/wuhu`)).ino
      const next = await install(site.base, { WUHU_LANE: 'dev' }, home)
      assertEquals(next.current, '0.1.0-dev.30')
      const after = (await Deno.lstat(`${home}/.wuhu/bin/wuhu`)).ino
      assertEquals(after !== before, true, 'a new inode, never written into')
      const leftovers = [...Deno.readDirSync(`${home}/.wuhu/bin`)]
        .map((entry) => entry.name)
        .filter((name) => /^\.wuhu-/.test(name))
      assertEquals(leftovers.length, 0, 'no temp files left behind')

      const badVersion = await install(site.base, { WUHU_VERSION: '../x' })
      assertEquals(badVersion.code, 1)
      assertEquals(badVersion.stderr.includes('invalid version'), true)

      const noLane = await install(site.base, { WUHU_LANE: 'nightly' })
      assertEquals(noLane.code, 1)
      assertEquals(noLane.current, null)
    } finally {
      await site.close()
    }
  },
})

Deno.test({
  name: 'install.sh refuses an artifact whose sha256 does not match',
  ignore: hostPlatform === undefined,
  async fn() {
    const work = await Deno.makeTempDir()
    const beta = await packageRelease(work, '0.1.0-beta.8')
    const site = serve(
      { beta: { version: '0.1.0-beta.8', release: beta } },
      [beta],
      new Set([beta.name]),
    )
    try {
      const envs: Record<string, string>[] = [
        {},
        { WUHU_VERSION: '0.1.0-beta.8' },
      ]
      for (const env of envs) {
        const result = await install(site.base, env)
        assertEquals(result.code, 1)
        assertEquals(result.stderr.includes('checksum mismatch'), true)
        assertEquals(result.current, null)
      }
    } finally {
      await site.close()
    }
  },
})

Deno.test('index.html names no release version', async () => {
  const html = await Deno.readTextFile(`${siteDir}/index.html`)
  const version = /\d+\.\d+\.\d+-(?:dev|beta)\.\d+/.exec(html)
  assertEquals(version?.[0], undefined)
})

Deno.test('before the pointer loads, the pill is hidden and downloads go to install.sh', async () => {
  const html = await Deno.readTextFile(`${siteDir}/index.html`)
  assertEquals(/<span class="pill" id="ver" hidden><\/span>/.test(html), true)
  const downloads = [
    ...html.matchAll(/<a class="dl" id="[^"]+" href="([^"]*)">/g),
  ]
    .map((match) => match[1])
  assertEquals(JSON.stringify(downloads), '["/install.sh","/install.sh"]')
})

Deno.test('the homepage Docs link uses the canonical extensionless landing', async () => {
  const html = await Deno.readTextFile(`${siteDir}/index.html`)
  if (!html.includes('href="/docs">Docs</a>')) {
    throw new Error('Canonical Docs link missing')
  }
})

Deno.test('the hero and install section offer apps alongside the unchanged CLI command', async () => {
  const html = await Deno.readTextFile(`${siteDir}/index.html`)
  const sections = [
    html.match(/<header>([\s\S]*?)<\/header>/)?.[1],
    html.match(/<section id="install">([\s\S]*?)<\/section>/)?.[1],
  ]
  const apps = [
    ['https://wuhu.ai/releases/app/mac/latest/Wuhu.zip', 'Download for Mac'],
    ['https://apps.apple.com/app/id6807771419', 'Download on the App Store'],
  ]
  for (const section of sections) {
    if (!section) throw new Error('Homepage section missing')
    const links = [
      ...section.matchAll(/<a\b[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/g),
    ]
    for (const [href, label] of apps) {
      const matches = links.filter((link) => link[1] === href)
      assertEquals(matches.length, 1, `App link ${href}`)
      assertEquals(matches[0][2], label)
    }
    assertEquals(
      section.includes(
        'data-copy="curl -fsSL https://wuhu.ai/install.sh | sh"',
      ),
      true,
      'CLI install command unchanged',
    )
  }
  const heroCTA = sections[0]!.match(
    /<div class="cta-row[^"]*">([\s\S]*?)<\/div>/,
  )?.[1]
  if (!heroCTA) throw new Error('Hero CTA row missing')
  assertEquals(
    [...heroCTA.matchAll(/<a\b/g)].length,
    2,
    'Only the two app links accompany the hero CLI command',
  )
})

Deno.test('the homepage sends Windows and Linux to /download from the hero and install section', async () => {
  const html = await Deno.readTextFile(`${siteDir}/index.html`)
  const sections = [
    html.match(/<header>([\s\S]*?)<\/header>/)?.[1],
    html.match(/<section id="install">([\s\S]*?)<\/section>/)?.[1],
  ]
  for (const section of sections) {
    if (!section) throw new Error('Homepage section missing')
    const links = [
      ...section.matchAll(/<a\b[^>]*href="\/download"[^>]*>(.*?)<\/a>/g),
    ]
    assertEquals(links.length, 1, 'One /download link')
    assertEquals(links[0][1], 'Windows and Linux')
  }
})

Deno.test('download.html offers all four apps and names no version before the pointer loads', async () => {
  const html = await Deno.readTextFile(`${siteDir}/download.html`)
  const hrefs = [...html.matchAll(/<a\b[^>]*href="([^"]*)"/g)].map((m) => m[1])
  for (
    const href of [
      'https://wuhu.ai/releases/app/mac/latest/Wuhu.zip',
      'https://wuhu.ai/releases/app/windows/latest/Wuhu-Setup.exe',
      'https://wuhu.ai/releases/app/linux/latest/wuhu.deb',
      'https://apps.apple.com/app/id6807771419',
    ]
  ) {
    assertEquals(hrefs.filter((h) => h === href).length, 1, href)
  }
  assertEquals(
    html.includes("fetch('/releases/app/desktop/latest.json'"),
    true,
    'Reads the desktop pointer',
  )
  const text = html.replace(/<svg[\s\S]*?<\/svg>/g, '')
  assertEquals(/\b\d+\.\d+\.\d+\b/.exec(text)?.[0], undefined)
})

// download.html's script, run against a stand-in document, navigator and
// fetch: which card it highlights and what it does with the desktop pointer.
async function runDownloadPage(
  userAgent: string,
  maxTouchPoints: number,
  pointer: (() => Promise<Response>) | null,
) {
  const html = await Deno.readTextFile(`${siteDir}/download.html`)
  const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1]
  if (!script) throw new Error('download.html script missing')
  const element = (id: string) => {
    const classes = new Set<string>()
    const tag = { hidden: true }
    const btn = {
      classList: {
        has: (name: string) => classes.has(`btn ${name}`),
        replace: (from: string, to: string) => {
          if (classes.delete(`btn ${from}`)) classes.add(`btn ${to}`)
        },
      },
    }
    classes.add('btn soft')
    return {
      id,
      href: `default:${id}`,
      textContent: `default:${id}`,
      title: '',
      tag,
      btn,
      classList: {
        add: (name: string) => classes.add(name),
        contains: (name: string) => classes.has(name),
      },
      querySelector: (selector: string) =>
        selector === '.tag' ? tag : selector === '.btn' ? btn : null,
    }
  }
  const elements = new Map(
    [
      'app-mac',
      'app-windows',
      'app-linux',
      'app-store',
      'dl-windows',
      'dl-windows-meta',
      'dl-linux',
      'dl-linux-meta',
      'dl-linux-cmd',
    ].map((id) => [id, element(id)]),
  )
  const fetched: string[] = []
  const fakeFetch = (url: string) => {
    fetched.push(url)
    return pointer ? pointer() : Promise.reject(new TypeError('offline'))
  }
  const loaded = new Function(
    'navigator',
    'document',
    'fetch',
    `${script}\nreturn desktopLoaded`,
  )(
    { userAgent, maxTouchPoints },
    { getElementById: (id: string) => elements.get(id) ?? null },
    fakeFetch,
  )
  await loaded
  const highlighted = ['mac', 'windows', 'linux', 'store'].filter((name) => {
    const card = elements.get(`app-${name}`)!
    const mine = card.classList.contains('mine')
    assertEquals(card.tag.hidden, !mine, `${name} tag`)
    assertEquals(card.btn.classList.has('solid'), mine, `${name} button`)
    return mine
  })
  assertEquals(
    JSON.stringify(fetched),
    '["/releases/app/desktop/latest.json"]',
  )
  return { highlighted, elements }
}

const userAgents = {
  iPhone:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  mac:
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
  windows:
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
  linux:
    'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0',
  android:
    'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
}

Deno.test('download.html highlights the visitor platform', async () => {
  const cases: [string, number, string][] = [
    [userAgents.iPhone, 5, 'store'],
    // iPadOS asks for the desktop site with a Mac user agent.
    [userAgents.mac, 5, 'store'],
    [userAgents.mac, 0, 'mac'],
    [userAgents.windows, 0, 'windows'],
    [userAgents.linux, 0, 'linux'],
    [userAgents.android, 5, ''],
  ]
  for (const [userAgent, touchPoints, expected] of cases) {
    const { highlighted } = await runDownloadPage(userAgent, touchPoints, null)
    assertEquals(highlighted.join(), expected, userAgent)
  }
})

const validPointer = {
  version: '0.1.0',
  artifacts: {
    windows: {
      name: 'Wuhu-Setup-0.1.0-x64.exe',
      url:
        'https://wuhu.ai/releases/app/windows/0.1.0/Wuhu-Setup-0.1.0-x64.exe',
      sha256: 'a'.repeat(64),
      size: 111225104,
    },
    linux: {
      name: 'wuhu-desktop_0.1.0_amd64.deb',
      url:
        'https://wuhu.ai/releases/app/linux/0.1.0/wuhu-desktop_0.1.0_amd64.deb',
      sha256: 'b'.repeat(64),
      size: 99199488,
    },
  },
}

Deno.test('download.html moves Windows and Linux to a valid pointer release', async () => {
  const { elements } = await runDownloadPage(
    userAgents.linux,
    0,
    () => Promise.resolve(Response.json(validPointer)),
  )
  const get = (id: string) => elements.get(id)!
  assertEquals(get('dl-windows').href, validPointer.artifacts.windows.url)
  assertEquals(get('dl-linux').href, validPointer.artifacts.linux.url)
  assertEquals(get('dl-windows-meta').textContent, 'Version 0.1.0 · 111 MB')
  assertEquals(get('dl-linux-meta').textContent, 'Version 0.1.0 · 99 MB')
  assertEquals(
    get('dl-linux-meta').title,
    `wuhu-desktop_0.1.0_amd64.deb\nsha256 ${'b'.repeat(64)}`,
  )
  assertEquals(
    get('dl-linux-cmd').textContent,
    'sudo apt install ./wuhu-desktop_0.1.0_amd64.deb',
  )
})

Deno.test('download.html keeps the latest/ links when the pointer is missing or malformed', async () => {
  const broken = (change: (pointer: typeof validPointer) => void) => {
    const pointer = structuredClone(validPointer)
    change(pointer)
    return () => Promise.resolve(Response.json(pointer))
  }
  const cases: [string, (() => Promise<Response>) | null][] = [
    ['offline', null],
    ['404', () => Promise.resolve(new Response('no', { status: 404 }))],
    ['not JSON', () => Promise.resolve(new Response('<html>'))],
    ['JSON null', () => Promise.resolve(Response.json(null))],
    ['no version', broken((p) => (p.version = undefined as never))],
    [
      'no linux',
      broken((p) => delete (p.artifacts as Partial<typeof p.artifacts>).linux),
    ],
    [
      'foreign url',
      broken((p) => (p.artifacts.windows.url = 'https://example.com/x.exe')),
    ],
    [
      'url of another version',
      broken((
        p,
      ) => (p.artifacts.linux.url = p.artifacts.linux.url.replace(
        '/0.1.0/',
        '/0.0.9/',
      ))),
    ],
    ['bad sha256', broken((p) => (p.artifacts.linux.sha256 = 'nope'))],
    [
      'shell in the name',
      broken((p) => (p.artifacts.linux.name = 'x; rm -rf ~.deb')),
    ],
  ]
  for (const [label, pointer] of cases) {
    const { elements } = await runDownloadPage(userAgents.windows, 0, pointer)
    for (const id of ['dl-windows', 'dl-linux']) {
      assertEquals(elements.get(id)!.href, `default:${id}`, `${label} ${id}`)
    }
    for (const id of ['dl-windows-meta', 'dl-linux-meta', 'dl-linux-cmd']) {
      assertEquals(
        elements.get(id)!.textContent,
        `default:${id}`,
        `${label} ${id}`,
      )
    }
  }
})
