import {
  admitFiles,
  attachmentDetail,
  attachmentDisplay,
  attachmentName,
  attachmentURL,
  formatSize,
} from './attachments.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const everything = () => true
const nothing = () => false

Deno.test('a video plays inline only where the browser can play its type', () => {
  const clip = {
    kind: 'file' as const,
    path: '/x/demo.mp4',
    mimeType: 'video/mp4',
  }
  assertEquals(attachmentDisplay(clip, everything), 'video')
  assertEquals(attachmentDisplay(clip, nothing), 'file')
  assertEquals(
    attachmentDisplay({
      kind: 'file',
      path: '/x/a.pdf',
      mimeType: 'application/pdf',
    }, everything),
    'file',
  )
  assertEquals(
    attachmentDisplay({
      kind: 'image',
      path: '/x/a.png',
      mimeType: 'image/png',
    }, nothing),
    'image',
  )
})

Deno.test('a file row names the file and gives its type and size', () => {
  assertEquals(
    attachmentName('/_/conversations/c/attachments/a/q3 report.pdf'),
    'q3 report.pdf',
  )
  assertEquals(
    attachmentDetail({
      kind: 'file',
      path: '/x/a.pdf',
      mimeType: 'application/pdf',
      size: 2_516_582,
    }),
    'application/pdf · 2.5 MB',
  )
  assertEquals(
    attachmentDetail({
      kind: 'file',
      path: '/x/a.bin',
      mimeType: 'application/octet-stream',
    }),
    'application/octet-stream',
  )
  assertEquals(formatSize(912), '912 bytes')
  assertEquals(formatSize(41_943_040), '42 MB')
  assertEquals(formatSize(157_286_400), '157 MB')
  assertEquals(formatSize(3_000_000_000), '3.0 GB')
})

Deno.test('a file opens from the content origin with each segment escaped', () => {
  assertEquals(
    attachmentURL(
      'https://space.example:5531',
      '/_/conversations/c/attachments/a/q3 report#1.pdf',
    ),
    'https://space.example:5531/_/conversations/c/attachments/a/q3%20report%231.pdf',
  )
})

Deno.test("another group's attachment opens at its hostless path on the viewer's origin", () => {
  for (
    const path of [
      'wuhu://alice.localspace/_/conversations/c/attachments/a/dm.txt',
      'wuhu://Alice.localspace/_/conversations/c/attachments/a/dm.txt',
    ]
  ) {
    assertEquals(
      attachmentURL('https://bob.space.example:5531', path),
      'https://bob.space.example:5531/_/conversations/c/attachments/a/dm.txt',
    )
  }
})

const MiB = 1024 * 1024
const sized = (name: string, size: number) => ({ name, size })

Deno.test('files under every limit are all admitted', () => {
  const incoming = [sized('a.png', MiB), sized('b.pdf', 50 * MiB)]
  assertEquals(admitFiles([], incoming), { admitted: incoming, refusal: null })
})

Deno.test('a ninth file is refused by name', () => {
  const held = Array.from({ length: 7 }, (_, i) => sized(`${i}.png`, 1))
  const result = admitFiles(held, [sized('h.png', 1), sized('i.png', 1)])
  assertEquals(result.admitted.map((file) => file.name), ['h.png'])
  assertEquals(
    result.refusal,
    'Not attached. i.png: a message can carry at most 8 files.',
  )
})

Deno.test('a file over 50 MiB is refused and the rest still fit', () => {
  const result = admitFiles([], [
    sized('big.mov', 50 * MiB + 1),
    sized('ok.txt', 10),
  ])
  assertEquals(result.admitted.map((file) => file.name), ['ok.txt'])
  assertEquals(
    result.refusal,
    'Not attached. big.mov: a file can be at most 50 MiB.',
  )
})

Deno.test('files past 150 MiB in all are refused', () => {
  const held = [sized('a.mov', 50 * MiB), sized('b.mov', 50 * MiB)]
  const result = admitFiles(held, [
    sized('c.mov', 50 * MiB),
    sized('d.mov', 1),
    sized('e.mov', 50 * MiB),
  ])
  assertEquals(result.admitted.map((file) => file.name), ['c.mov'])
  assertEquals(
    result.refusal,
    'Not attached. d.mov, e.mov: a message can carry at most 150 MiB in all.',
  )
})

Deno.test('an oversized file is named as oversized even past the count', () => {
  const held = Array.from({ length: 8 }, (_, i) => sized(`${i}.png`, 1))
  const result = admitFiles(held, [
    sized('big.mov', 51 * MiB),
    sized('j.png', 1),
  ])
  assertEquals(result.admitted, [])
  assertEquals(
    result.refusal,
    'Not attached. big.mov: a file can be at most 50 MiB. j.png: a message can carry at most 8 files.',
  )
})

Deno.test('active attachment types are files even if their payload says image', () => {
  for (
    const mimeType of [
      'text/html',
      'application/xhtml+xml',
      'image/svg+xml',
      'application/xml',
      'text/xml',
    ]
  ) {
    assertEquals(
      attachmentDisplay(
        { kind: 'image', path: '/proof.svg', mimeType },
        everything,
      ),
      'file',
    )
  }
})
