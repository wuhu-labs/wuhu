import { renderToStaticMarkup } from 'react-dom/server'
import { FileCard } from '../components/file-view.tsx'

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`expected\n${String(expected)}\ngot\n${String(actual)}`)
  }
}

Deno.test('the file card names the file, its kind and size, and downloads it', () => {
  const markup = renderToStaticMarkup(
    <FileCard
      path='/evidence/build-logs.zip'
      size={40_710}
      src='https://shared.space.test/evidence/build-logs.zip'
    />,
  )
  assertEquals(
    markup.replace(/<svg.*?<\/svg>/g, '<svg/>'),
    '<div class="wuhu-attachment-file wuhu-file-card"><svg/>' +
      '<span><strong>build-logs.zip</strong><span>ZIP file · 41 KB</span></span>' +
      '<a class="wuhu-button-secondary" href="https://shared.space.test/evidence/build-logs.zip?download=1">Download</a>' +
      '</div>',
  )
})

Deno.test('without a content origin the card has no download', () => {
  const markup = renderToStaticMarkup(
    <FileCard path='/LICENSE' src={null} />,
  )
  assertEquals(markup.includes('Download'), false)
  assertEquals(markup.includes('<span>File</span>'), true)
})
