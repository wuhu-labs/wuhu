import {
  newQuickJSWASMModuleFromVariant,
  newVariant,
  type QuickJSSyncVariant,
  type QuickJSWASMModule,
} from 'quickjs-emscripten-core'
import { QuickJSFFI } from '@jitl/quickjs-ng-wasmfile-release-sync/ffi'
import wasmLocation from './quickjs/emscripten-module.wasm?url'

// The engine is //tools/quickjs-wasm:quickjs, quickjs-ng 0.15.1 like the
// server's and native's QuickJSKit, driven through quickjs-emscripten 0.32's
// unchanged FFI. The build injects both files into ./quickjs/.
const variant: QuickJSSyncVariant = newVariant({
  type: 'sync',
  importFFI: () => Promise.resolve(QuickJSFFI),
  importModuleLoader: () =>
    import('./quickjs/emscripten-module.browser.mjs').then((loaded) =>
      loaded.default
    ),
}, { wasmLocation })

let loading: Promise<QuickJSWASMModule> | null = null

export function quickJS(): Promise<QuickJSWASMModule> {
  loading ??= newQuickJSWASMModuleFromVariant(variant)
  return loading
}
