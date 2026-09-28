import { assertEquals } from 'jsr:@std/assert@1'
import { base64URLToBytes } from './web-push.ts'

Deno.test('VAPID application keys decode from unpadded base64url', () => {
  assertEquals([...base64URLToBytes('AQID-_8')], [1, 2, 3, 251, 255])
})
