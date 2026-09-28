export function assertIncludes(haystack: string, needle: string): void {
  if (!haystack.includes(needle)) {
    throw new Error(
      `Expected output to include ${Deno.inspect(needle)}:\n${haystack}`,
    )
  }
}

export function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${Deno.inspect(actual)} to equal ${Deno.inspect(expected)}`,
    )
  }
}

export function assertThrows(
  fn: () => void,
  messageIncludes: string,
): void {
  try {
    fn()
  } catch (error) {
    if (!String(error).includes(messageIncludes)) {
      throw new Error(
        `Expected error to include ${Deno.inspect(messageIncludes)}, got: ${
          String(error)
        }`,
      )
    }
    return
  }
  throw new Error(
    `Expected function to throw including ${Deno.inspect(messageIncludes)}`,
  )
}
