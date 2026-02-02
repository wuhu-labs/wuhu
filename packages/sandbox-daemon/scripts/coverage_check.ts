import { dirname, fromFileUrl, join, normalize } from '@std/path'

interface CoverageTotals {
  lf: number
  lh: number
}

function parseArgs(args: string[]): { min: number; include: string } {
  const envMin = Deno.env.get('COVERAGE_MIN')?.trim()
  let min = envMin ? Number(envMin) : 0.6037
  let include = 'src'

  for (const arg of args) {
    if (arg.startsWith('--min=')) {
      min = Number(arg.slice('--min='.length))
    } else if (arg.startsWith('--include=')) {
      include = arg.slice('--include='.length)
    }
  }

  if (!Number.isFinite(min) || min < 0 || min > 1) {
    throw new Error(`invalid --min (${min}); expected 0..1`)
  }

  return { min, include }
}

async function run(cmd: string, args: string[], cwd: string): Promise<void> {
  const p = new Deno.Command(cmd, { args, cwd, stdin: 'null' }).spawn()
  const status = await p.status
  if (!status.success) {
    throw new Error(`${cmd} ${args.join(' ')} failed (code=${status.code})`)
  }
}

function parseLcov(text: string, includeSubstr: string): CoverageTotals {
  const records = text.split('end_of_record')
  let lf = 0
  let lh = 0

  for (const rec of records) {
    const sfLine = rec.match(/^SF:(.*)$/m)?.[1]?.trim()
    if (!sfLine) continue
    const sf = sfLine.replaceAll('\\', '/')
    if (!sf.includes(includeSubstr)) continue

    const lfLine = rec.match(/^LF:(\d+)$/m)?.[1]
    const lhLine = rec.match(/^LH:(\d+)$/m)?.[1]
    if (lfLine) lf += Number(lfLine)
    if (lhLine) lh += Number(lhLine)
  }

  return { lf, lh }
}

const { min, include } = parseArgs(Deno.args)

const scriptPath = fromFileUrl(import.meta.url)
const packageRoot = normalize(dirname(dirname(scriptPath)))
const coverageDir = join(packageRoot, 'coverage')
const lcovPath = join(packageRoot, 'coverage.lcov')

await run('deno', ['test', '-A', `--coverage=${coverageDir}`], packageRoot)
await run(
  'deno',
  ['coverage', coverageDir, '--lcov', `--output=${lcovPath}`],
  packageRoot,
)

const lcov = await Deno.readTextFile(lcovPath)
const includeSubstr = `/${
  join('packages', 'sandbox-daemon', include).replaceAll('\\', '/')
}/`
const totals = parseLcov(lcov, includeSubstr)

const pct = totals.lf === 0 ? 1 : totals.lh / totals.lf
const pctStr = (pct * 100).toFixed(2)
const minStr = (min * 100).toFixed(2)
const pctRounded = Number(pctStr) / 100
const minRounded = Number(minStr) / 100

console.log(
  `coverage: ${pctStr}% (${totals.lh}/${totals.lf} lines) include=${includeSubstr}`,
)

if (pctRounded < minRounded) {
  console.error(`coverage below minimum: ${pctStr}% < ${minStr}%`)
  Deno.exit(1)
}
