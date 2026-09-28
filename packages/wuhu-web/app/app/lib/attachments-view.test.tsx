import { renderToStaticMarkup } from 'react-dom/server'
import { Attachments } from '../components/attachments.tsx'

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`expected\n${String(expected)}\ngot\n${String(actual)}`)
  }
}

const origin = 'https://space.test'

Deno.test('a video plays inline beside the images and a file is a row that opens it', () => {
  const markup = renderToStaticMarkup(
    <Attachments
      origin={origin}
      canPlay={(type) => type === 'video/mp4'}
      attachments={[
        { kind: 'image', path: '/a/shot.png', mimeType: 'image/png' },
        {
          kind: 'file',
          path: '/a/demo.mp4',
          mimeType: 'video/mp4',
          size: 41_943_040,
        },
        {
          kind: 'file',
          path: '/a/report.pdf',
          mimeType: 'application/pdf',
          size: 2_516_582,
        },
      ]}
    />,
  )
  assertEquals(
    markup.replace(/<svg.*?<\/svg>/g, '<svg/>'),
    '<div class="wuhu-attachments">' +
      '<div class="wuhu-attachment-media">' +
      '<a class="wuhu-attachment-tile" href="https://space.test/a/shot.png" target="_blank" rel="noreferrer">' +
      '<img src="https://space.test/a/shot.png" alt="shot.png" loading="lazy"/></a>' +
      '<video class="wuhu-attachment-tile" src="https://space.test/a/demo.mp4" controls="" playsInline="" preload="metadata" aria-label="demo.mp4"></video>' +
      '</div>' +
      '<a class="wuhu-attachment-file" href="https://space.test/a/report.pdf" target="_blank" rel="noreferrer">' +
      '<svg/><span><strong>report.pdf</strong><span>application/pdf · 2.5 MB</span></span></a>' +
      '</div>',
  )
})

Deno.test('a video the browser cannot play is a file row', () => {
  const markup = renderToStaticMarkup(
    <Attachments
      origin={origin}
      canPlay={() => false}
      attachments={[{
        kind: 'file',
        path: '/a/clip.webm',
        mimeType: 'video/webm',
        size: 912,
      }]}
    />,
  )
  assertEquals(markup.includes('<video'), false)
  assertEquals(
    markup.includes(
      '<strong>clip.webm</strong><span>video/webm · 912 bytes</span>',
    ),
    true,
  )
})
