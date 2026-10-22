import { newQuickJSWASMModuleFromVariant } from './core/index.mjs'
import { QuickJSFFI } from './ffi.mjs'

function equal(actual: unknown, expected: unknown) {
  if (actual !== expected) {
    throw new Error(`Expected ${expected}, received ${actual}`)
  }
}

self.onmessage = async (event) => {
  try {
    const quickjs = await newQuickJSWASMModuleFromVariant({
      type: 'sync',
      importFFI: () => Promise.resolve(QuickJSFFI),
      importModuleLoader: () => import(event.data),
    })
    const ffi = quickjs.getFFI()
    for (
      const name of Object.keys(ffi).filter((key) => key.startsWith('QTS_'))
    ) {
      equal(typeof ffi.module[`_${name}`], 'function')
    }
    {
      using runtime = quickjs.newRuntime()
      using context = runtime.newContext()
      using number = context.unwrapResult(context.evalCode('Number(6n * 7n)'))
      equal(context.getNumber(number), 42)

      using namespace = context.unwrapResult(
        context.evalCode('export const answer = 42', 'answer.mjs'),
      )
      using answer = context.getProp(namespace, 'answer')
      equal(context.getNumber(answer), 42)

      runtime.setModuleLoader((name) => {
        equal(name, 'dependency')
        return 'export const value = 21'
      })
      using imported = context.unwrapResult(
        context.evalCode(
          'import { value } from "dependency"; export const answer = value * 2',
          'import.mjs',
        ),
      )
      using importedAnswer = context.getProp(imported, 'answer')
      equal(context.getNumber(importedAnswer), 42)

      using deferred = context.newPromise()
      using host = context.newFunction('host', () => deferred.handle)
      context.setProp(context.global, 'host', host)
      using promise = context.unwrapResult(
        context.evalCode('(async () => (await host()) * 2)()'),
      )
      const resolved = context.resolvePromise(promise)
      using hostValue = context.newNumber(21)
      deferred.resolve(hostValue)
      context.unwrapResult(runtime.executePendingJobs())
      using result = context.unwrapResult(await resolved)
      equal(context.getNumber(result), 42)

      let interrupts = 0
      runtime.setInterruptHandler(() => ++interrupts > 1)
      const interrupted = context.evalCode('while (true) {}')
      if (!interrupted.error) throw new Error('Expected interruption')
      using interruption = interrupted.error
      equal(context.dump(interruption).message, 'interrupted')
      runtime.removeInterruptHandler()
    }
    self.postMessage({ success: true })
  } catch (error) {
    self.postMessage({
      error: error instanceof Error ? error.stack : String(error),
    })
  }
}
