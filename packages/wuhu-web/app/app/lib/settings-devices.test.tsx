import { renderToStaticMarkup } from 'react-dom/server'
import { assert } from 'jsr:@std/assert@1'
import { DevicesCard } from '~/components/settings-devices'

Deno.test('a browser with its own key can invite a device and log out', () => {
  const actual = renderToStaticMarkup(<DevicesCard signOut={() => {}} />)
  assert(actual.includes('Invite a device'), actual)
  assert(actual.includes('Log out'), actual)
})

Deno.test('a browser without its own key offers no device invite', () => {
  const actual = renderToStaticMarkup(<DevicesCard signOut={null} />)
  assert(!actual.includes('<button'), actual)
  assert(actual.includes('invite a device'), actual)
})
