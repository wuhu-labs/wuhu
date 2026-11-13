const fixtures: [string[], string[]][] = [
  [
    ['Sources/Violations.swift'],
    [
      'duplicate_conditions',
      'no_nslock',
      'no_jsonserialization',
      'no_task_sleep',
      'no_combine_import',
      'no_unchecked_sendable',
      'no_observable_object',
      'superfluous_disable_command',
      'testable_import_outside_tests',
    ],
  ],
  [['Tests/Allowed.swift', 'Tests/TestableImportTests.swift'], []],
  [['Sources/Allowed.swift'], []],
  [['Sources/MissingReason.swift'], ['ban_disable_requires_reason']],
  [['Sources/BlanketDisable.swift'], ['blanket_disable_command']],
  [['Sources/DisableAll.swift'], ['blanket_disable_command']],
  [['Sources/ThisDisable.swift'], ['ban_disable_requires_reason']],
  [['Sources/PreviousDisable.swift'], ['ban_disable_requires_reason']],
  [['Sources/MultipleDisable.swift'], ['ban_disable_requires_reason']],
  [['Sources/PairedDisable.swift'], ['ban_disable_requires_reason']],
]

async function lint(files: string[]) {
  const result = await new Deno.Command('swiftlint', {
    args: [
      'lint',
      '--force-exclude',
      '--strict',
      '--quiet',
      '--no-cache',
      '--config',
      '.swiftlint.yml',
      '--',
      ...files,
    ],
  }).output()
  return {
    code: result.code,
    text: new TextDecoder().decode(result.stdout) +
      new TextDecoder().decode(result.stderr),
  }
}

for (const [files, expected] of fixtures) {
  Deno.test(files.join(', '), async () => {
    const { code, text } = await lint(
      files.map((file) => `bazel/swiftlint/testdata/${file}`),
    )
    if (code !== (expected.length ? 2 : 0)) {
      throw new Error(`Unexpected exit ${code}:\n${text}`)
    }
    for (const id of new Set(expected)) {
      const count = expected.filter((value) => value === id).length
      if (text.split(`(${id})`).length - 1 < count) {
        throw new Error(`Missing ${count} ${id} violations:\n${text}`)
      }
    }
  })
}

Deno.test('token rules ignore trivia, comments and strings, and keep path scopes', async () => {
  const root = await Deno.makeTempDir()
  try {
    const cases: [string, string, string[]][] = [
      [
        'Sources/Tokens.swift',
        `@testable /* outer /* nested */ done */ import Foundation
final class A: @unchecked /* trivia */ Other.Sendable {}
func value(_ argument: any ObservableObject) {}
struct Model { @Published var value = 0; @ObservedObject var other: Other }
// @testable @unchecked ObservableObject @Published @ObservedObject
let text = "@testable @unchecked ObservableObject @Published @ObservedObject"
`,
        [
          'testable_import_outside_tests',
          'no_unchecked_sendable',
          'no_observable_object',
          'no_observable_object',
          'no_observable_object',
        ],
      ],
      [
        'Sources/Whitespace.swift',
        `@ testable import Foundation
final class A: @ unchecked Sendable {}
struct B { @ Published var value = 0; @ ObservedObject var other: Other }
@
 testable import Foundation
final class C: @
 unchecked Sendable {}
struct D { @
 Published var value = 0; @
 ObservedObject var other: Other }
// @ testable @ unchecked @ Published @ ObservedObject
let text = "@ testable @ unchecked @ Published @ ObservedObject"
`,
        [
          'testable_import_outside_tests',
          'testable_import_outside_tests',
          'no_unchecked_sendable',
          'no_unchecked_sendable',
          'no_observable_object',
          'no_observable_object',
          'no_observable_object',
          'no_observable_object',
        ],
      ],
      [
        'FeatureTests/Sources/Allowed.swift',
        '@testable import Foundation\n',
        [],
      ],
      [
        'Tests/Allowed.swift',
        'class A: @unchecked Other.Sendable, ObservableObject { @Published var value = 0 }\n',
        [],
      ],
    ]
    for (const [path, text, expected] of cases) {
      const file = `${root}/${path}`
      await Deno.mkdir(file.slice(0, file.lastIndexOf('/')), {
        recursive: true,
      })
      await Deno.writeTextFile(file, text)
      const { code, text: output } = await lint([file])
      if (code !== (expected.length ? 2 : 0)) {
        throw new Error(`${path}: exit ${code}\n${output}`)
      }
      for (const id of new Set(expected)) {
        if (
          output.split(`(${id})`).length - 1 !==
            expected.filter((rule) => rule === id).length
        ) {
          throw new Error(`${path}: wrong ${id} count\n${output}`)
        }
      }
    }
  } finally {
    await Deno.remove(root, { recursive: true })
  }
})
