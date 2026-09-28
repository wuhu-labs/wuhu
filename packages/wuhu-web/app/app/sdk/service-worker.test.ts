import { assertEquals, assertRejects } from 'jsr:@std/assert@1'
import {
  navigationResponse,
  notificationDestination,
} from '../../public/_/service-worker.js'

const page = new Request('https://app.test/notes/today.md')

function recorder(answer: (request: Request) => Promise<Response>) {
  const asked: { url: string; cache: RequestCache }[] = []
  const fetch = (request: Request) => {
    asked.push({ url: request.url, cache: request.cache })
    return answer(request)
  }
  return { asked, fetch }
}

Deno.test('online, the app shell comes from the network untouched', async () => {
  const { asked, fetch } = recorder(() => Promise.resolve(new Response('new')))
  assertEquals(await (await navigationResponse(page, fetch)).text(), 'new')
  assertEquals(asked, [{ url: page.url, cache: 'default' }])
})

Deno.test('offline, the shell is only what the HTTP cache already holds', async () => {
  const { asked, fetch } = recorder((request) =>
    request.cache !== 'only-if-cached'
      ? Promise.reject(new TypeError('offline'))
      : request.url === 'https://app.test/'
      ? Promise.resolve(new Response('kept root'))
      : Promise.reject(new TypeError('not cached'))
  )
  assertEquals(
    await (await navigationResponse(page, fetch)).text(),
    'kept root',
  )
  assertEquals(asked, [
    { url: page.url, cache: 'default' },
    { url: page.url, cache: 'only-if-cached' },
    { url: 'https://app.test/', cache: 'only-if-cached' },
  ])
})

Deno.test('offline with nothing held, the navigation fails as the browser would', async () => {
  const { fetch } = recorder(() => Promise.reject(new TypeError('offline')))
  await assertRejects(() => navigationResponse(page, fetch), TypeError)
})

Deno.test('a notification opens in its group', () => {
  assertEquals(
    notificationDestination({
      navigate: 'https://space.example/_/conversations/abc',
      data: { destination: '/_/conversations/abc', group: 'sail-clock-pepper' },
    }),
    '/_/conversations/abc?group=sail-clock-pepper',
  )
  assertEquals(
    notificationDestination({
      data: { destination: '/_/sessions/zebra-forest-bike', group: 'shared' },
    }),
    '/_/sessions/zebra-forest-bike',
  )
})
