import type { QuickJSSyncVariant } from 'quickjs-emscripten-core'

// //tools/quickjs-wasm:quickjs's loader, generated next to this file.
declare const QuickJSRaw: Awaited<
  ReturnType<QuickJSSyncVariant['importModuleLoader']>
>
export default QuickJSRaw
