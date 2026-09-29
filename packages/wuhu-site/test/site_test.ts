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
