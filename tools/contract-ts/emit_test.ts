import { emitContract, renderType, type Schema } from './emit.ts'

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

function assertStringIncludes(haystack: string, needle: string): void {
  if (!haystack.includes(needle)) {
    throw new Error(
      `expected output to include ${JSON.stringify(needle)}:\n${haystack}`,
    )
  }
}

function assertThrows(body: () => unknown, message: string): void {
  try {
    body()
  } catch (error) {
    const text = error instanceof Error ? error.message : String(error)
    if (!text.includes(message)) {
      throw new Error(
        `expected error including ${JSON.stringify(message)}, got ${text}`,
      )
    }
    return
  }
  throw new Error(`expected a throw including ${JSON.stringify(message)}`)
}

Deno.test('string enum becomes a union type alias', () => {
  const schema: Schema = {
    title: 'EntryKind',
    type: 'string',
    enum: ['file', 'directory', 'table'],
  }
  assertStringIncludes(
    emitContract([schema]),
    'export type EntryKind = "file" | "directory" | "table";',
  )
})

Deno.test('object becomes an interface with optional and nullable fields', () => {
  const schema: Schema = {
    title: 'Entry',
    type: 'object',
    properties: {
      name: { type: 'string' },
      lineCount: { type: ['integer', 'null'] },
      mtime: { type: 'number' },
    },
    required: ['name', 'mtime'],
  }
  const output = emitContract([schema])
  assertStringIncludes(output, 'export interface Entry {')
  assertStringIncludes(output, '  name: string;')
  assertStringIncludes(output, '  lineCount?: number | null;')
  assertStringIncludes(output, '  mtime: number;')
})

Deno.test('oneOf with const discriminators becomes a tagged union', () => {
  const schema: Schema = {
    title: 'MutationEvent',
    oneOf: [
      {
        type: 'object',
        properties: { kind: { const: 'write' }, rev: { type: 'integer' } },
        required: ['kind', 'rev'],
      },
      {
        type: 'object',
        properties: { kind: { const: 'delete' }, rev: { type: 'integer' } },
        required: ['kind', 'rev'],
      },
    ],
  }
  const output = emitContract([schema])
  assertStringIncludes(output, 'export type MutationEvent = {')
  assertStringIncludes(output, '  kind: "write";')
  assertStringIncludes(output, '  kind: "delete";')
  assertStringIncludes(output, '} | {')
})

Deno.test('arrays of unions are parenthesized', () => {
  const schema: Schema = {
    type: 'array',
    items: {
      oneOf: [
        {
          type: 'object',
          properties: { kind: { const: 'a' } },
          required: ['kind'],
        },
        {
          type: 'object',
          properties: { kind: { const: 'b' } },
          required: ['kind'],
        },
      ],
    },
  }
  const rendered = renderType(schema, 'Test', '')
  assertStringIncludes(rendered, ')[]')
  assertStringIncludes(rendered, '({')
})

Deno.test('anyOf of enum and null renders a nullable union', () => {
  const rendered = renderType(
    {
      anyOf: [{ type: 'string', enum: ['user', 'session'] }, { type: 'null' }],
    },
    'senderKind',
    '',
  )
  assertEquals(rendered, '"user" | "session" | null')
})

Deno.test('nullable array of strings', () => {
  const rendered = renderType(
    { type: ['array', 'null'], items: { type: 'string' } },
    'tags',
    '',
  )
  assertEquals(rendered, 'string[] | null')
})

Deno.test('empty schema renders unknown', () => {
  assertEquals(renderType({}, 'payload', ''), 'unknown')
})

Deno.test('declarations are emitted in sorted title order', () => {
  const output = emitContract([
    { title: 'Zebra', type: 'string', enum: ['z'] },
    { title: 'Apple', type: 'string', enum: ['a'] },
  ])
  assertEquals(
    output.indexOf('Apple') < output.indexOf('Zebra'),
    true,
  )
})

Deno.test('crash on unknown scalar type', () => {
  assertThrows(
    () => renderType({ type: 'weird' } as unknown as Schema, 'x', ''),
    'unsupported schema construct',
  )
})

Deno.test('crash on non-string enum', () => {
  assertThrows(
    () => renderType({ type: 'integer', enum: [1, 2] }, 'x', ''),
    'unsupported schema construct',
  )
})

Deno.test('crash on object without properties', () => {
  assertThrows(
    () => renderType({ type: 'object' }, 'x', ''),
    'unsupported schema construct',
  )
})

Deno.test('crash on array without items', () => {
  assertThrows(
    () => renderType({ type: 'array' }, 'x', ''),
    'unsupported schema construct',
  )
})

Deno.test('crash on missing title at declaration level', () => {
  assertThrows(
    () => emitContract([{ type: 'string', enum: ['a'] }]),
    'missing a title',
  )
})
