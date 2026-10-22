// The page and the script worker talk in these messages. A run's host calls
// come back to the page, which answers each by its call number.
export type ToWorker =
  | { kind: 'run'; run: number; code: string; file: string; props: unknown }
  | { kind: 'cancel'; run: number }
  | { kind: 'answer'; run: number; call: number; text: string }
  | { kind: 'refuse'; run: number; call: number; message: string }

export type FromWorker =
  | { kind: 'query'; run: number; call: number; sql: string; params: string }
  | { kind: 'fetch'; run: number; call: number; request: string }
  | { kind: 'done'; run: number; value: string; sizes: unknown }
  | { kind: 'failed'; run: number; message: string }
