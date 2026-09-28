export interface KeyboardViewportInput {
  baselineHeight: number
  height: number
  offsetTop: number
  scale: number
  textEntryFocused: boolean
}

export interface KeyboardViewport {
  height: number
  offsetTop: number
}

export function keyboardViewport(
  input: KeyboardViewportInput,
): KeyboardViewport | null {
  const occludedHeight = input.baselineHeight - input.height
  if (
    !input.textEntryFocused ||
    input.scale !== 1 ||
    occludedHeight < 100
  ) {
    return null
  }
  return {
    height: input.height,
    offsetTop: Math.max(0, input.offsetTop),
  }
}
