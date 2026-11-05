import * as glue from 'loro-crdt/web/loro_wasm.js'

// The glue is an ES module whose default export instantiates the WASM; its
// package declares no module type, so Deno types the import as CommonJS.
const init = (glue as unknown as { default: () => Promise<unknown> }).default

let loading: Promise<unknown> | undefined

// loro-crdt/web needs its WASM instantiated once before any Loro type is used.
export function loadLoro(): Promise<unknown> {
  loading ??= init()
  return loading
}

export function configuredDoc<
  Doc extends { configTextStyle(styles: object): void },
>(doc: Doc): Doc {
  doc.configTextStyle({
    bold: { expand: 'after' },
    italic: { expand: 'after' },
    link: { expand: 'none' },
    code: { expand: 'none' },
  })
  return doc
}
