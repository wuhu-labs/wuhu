export type HapticKind =
  | 'selection'
  | 'light'
  | 'medium'
  | 'heavy'
  | 'success'
  | 'warning'
  | 'error'

/** Best-effort feedback; unsupported devices and unknown kinds are ignored. */
export function haptic(kind: HapticKind): void
