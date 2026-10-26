import { assertEquals, assertStringIncludes, assertThrows } from '@std/assert'
import { emitContract, renderType, type Schema } from './emit.ts'

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
    Error,
    'unsupported schema construct',
  )
})

Deno.test('crash on non-string enum', () => {
  assertThrows(
    () => renderType({ type: 'integer', enum: [1, 2] }, 'x', ''),
    Error,
    'unsupported schema construct',
  )
})

Deno.test('crash on object without properties', () => {
  assertThrows(
    () => renderType({ type: 'object' }, 'x', ''),
    Error,
    'unsupported schema construct',
  )
})

Deno.test('crash on array without items', () => {
  assertThrows(
    () => renderType({ type: 'array' }, 'x', ''),
    Error,
    'unsupported schema construct',
  )
})

Deno.test('crash on missing title at declaration level', () => {
  assertThrows(
    () => emitContract([{ type: 'string', enum: ['a'] }]),
    Error,
    'missing a title',
  )
})
