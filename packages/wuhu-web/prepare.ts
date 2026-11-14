export async function prepare() {
  await Deno.mkdir('app/lib', { recursive: true })
  await Deno.copyFile(
    '../../../packages/wuhu-core/Targets/SpaceContract/Tests/contract/space-url-vectors.json',
    'app/lib/space-url.vectors.json',
  )
  await Deno.mkdir('app/lib', { recursive: true })
  await Deno.copyFile(
    '../../../packages/wuhu-core/Targets/SpaceContract/Tests/contract/viewing-vectors.json',
    'app/lib/viewing.vectors.json',
  )
  await Deno.mkdir('app/lib', { recursive: true })
  await Deno.copyFile(
    '../../../packages/wuhu-core/Targets/SpaceContract/Tests/contract/session-line-vectors.json',
    'app/lib/session-line.vectors.json',
  )
  await Deno.mkdir('app/lib/canvas', { recursive: true })
  await Deno.copyFile(
    '../../../packages/wuhu-core/Targets/CanvasDocument/Tests/Fixtures/scene-cases.json',
    'app/lib/canvas/scene-cases.json',
  )
  await Deno.mkdir('app/lib/canvas', { recursive: true })
  await Deno.copyFile(
    '../../../packages/wuhu-core/Targets/CanvasDocument/Tests/Fixtures/editor-cases.json',
    'app/lib/canvas/editor-cases.json',
  )
  await Deno.mkdir('app/lib/widgets/shared', { recursive: true })
  await Deno.copyFile(
    '../../../packages/widget-script-kit/Targets/WidgetScriptSource/Sources/Resources/prelude.js',
    'app/lib/widgets/shared/prelude.js',
  )
  await Deno.mkdir('app/lib/widgets/shared', { recursive: true })
  await Deno.copyFile(
    '../../../packages/widget-script-kit/Targets/WidgetScriptSource/Sources/Resources/tree.js',
    'app/lib/widgets/shared/tree.js',
  )
  await Deno.mkdir('app/lib/widgets/shared', { recursive: true })
  await Deno.copyFile(
    '../../../packages/widget-script-kit/Targets/WidgetScriptSource/Sources/Resources/prelude.d.ts',
    'app/lib/widgets/shared/prelude.d.ts',
  )
  await Deno.mkdir('app/lib/widgets/shared', { recursive: true })
  await Deno.copyFile(
    '../../../packages/widget-script-kit/Targets/WidgetScriptSource/Sources/Resources/tree.d.ts',
    'app/lib/widgets/shared/tree.d.ts',
  )
  await Deno.mkdir('../ui/src/shared', { recursive: true })
  await Deno.copyFile(
    '../../../packages/widget-script-kit/Targets/WidgetScriptSource/Sources/Resources/allowance.json',
    '../ui/src/shared/allowance.json',
  )
}
