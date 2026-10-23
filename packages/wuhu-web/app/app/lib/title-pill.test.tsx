import { renderToStaticMarkup } from 'react-dom/server'
import { assertStringIncludes } from 'jsr:@std/assert@1'
import { TitlePill } from '@wuhu/ui'

Deno.test('title pills keep text in the truncating span and avatars outside it', () => {
  for (const title of ['Settings', 'Channel', 'A long document title']) {
    assertStringIncludes(
      renderToStaticMarkup(<TitlePill>{title}</TitlePill>),
      `<span>${title}</span>`,
    )
  }
  const task = renderToStaticMarkup(
    <TitlePill lead={<img alt='Task' />}>Task title</TitlePill>,
  )
  assertStringIncludes(task, 'wui-pill-lead')
  assertStringIncludes(task, '<img alt="Task"/><span>Task title</span>')
})
