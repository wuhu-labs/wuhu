import {
  atBottom,
  type Follow,
  followAfterScroll,
  holdAnchor,
  scrollAfterResize,
} from './timeline-follow.ts'

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

const pinned: Follow = { following: true, scrollTop: 1200 }
const reading: Follow = { following: false, scrollTop: 400 }

Deno.test('the bottom is the last screen of content, within a small slack', () => {
  equal(
    atBottom({ scrollTop: 1200, scrollHeight: 2000, clientHeight: 800 }),
    true,
  )
  equal(
    atBottom({ scrollTop: 1160, scrollHeight: 2000, clientHeight: 800 }),
    true,
  )
  equal(
    atBottom({ scrollTop: 1159, scrollHeight: 2000, clientHeight: 800 }),
    false,
  )
})

Deno.test('scrolling up past the slack lets go of the latest message', () => {
  equal(
    followAfterScroll(pinned, {
      scrollTop: 900,
      scrollHeight: 2000,
      clientHeight: 800,
    }),
    { following: false, scrollTop: 900 },
  )
})

Deno.test('content growing under a pinned view keeps it pinned', () => {
  equal(
    followAfterScroll(pinned, {
      scrollTop: 1200,
      scrollHeight: 2600,
      clientHeight: 800,
    }),
    { following: true, scrollTop: 1200 },
  )
})

Deno.test('a shorter window at the bottom keeps following', () => {
  equal(
    followAfterScroll(pinned, {
      scrollTop: 1200,
      scrollHeight: 2000,
      clientHeight: 500,
    }),
    { following: true, scrollTop: 1200 },
  )
  equal(
    followAfterScroll(pinned, {
      scrollTop: 1000,
      scrollHeight: 2000,
      clientHeight: 1000,
    }),
    { following: true, scrollTop: 1000 },
  )
})

Deno.test('a reader in history stays there until they reach the bottom', () => {
  equal(
    followAfterScroll(reading, {
      scrollTop: 400,
      scrollHeight: 2600,
      clientHeight: 800,
    }),
    reading,
  )
  equal(
    followAfterScroll(reading, {
      scrollTop: 900,
      scrollHeight: 2600,
      clientHeight: 800,
    }),
    { following: false, scrollTop: 900 },
  )
  equal(
    followAfterScroll(reading, {
      scrollTop: 1800,
      scrollHeight: 2600,
      clientHeight: 800,
    }),
    { following: true, scrollTop: 1800 },
  )
})

Deno.test('a resize pins a following view to the bottom and leaves a reader alone', () => {
  const grown = { scrollTop: 1200, scrollHeight: 2600, clientHeight: 800 }
  equal(scrollAfterResize(pinned, grown), 1800)
  equal(scrollAfterResize(pinned, { ...grown, clientHeight: 500 }), 2100)
  equal(scrollAfterResize(reading, grown), null)
})

Deno.test('growth, then the scroll event the pin raises, keeps following', () => {
  const grown = { scrollTop: 1200, scrollHeight: 2600, clientHeight: 800 }
  const pinTo = scrollAfterResize(pinned, grown)!
  const after = followAfterScroll(pinned, { ...grown, scrollTop: pinTo })
  equal(after, { following: true, scrollTop: 1800 })
  equal(
    followAfterScroll(pinned, { ...grown, scrollHeight: 3000 }),
    { following: true, scrollTop: 1200 },
  )
})

Deno.test('a toggle lets go of the latest and keeps the clicked line in place', () => {
  equal(holdAnchor(1200, 300, 300), { following: false, scrollTop: 1200 })
  equal(holdAnchor(1200, 300, 340), { following: false, scrollTop: 1240 })
})
