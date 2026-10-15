import { assertEquals } from 'jsr:@std/assert@1'
import { holdSelection, selectionIn } from './list-selection.ts'

Deno.test('a highlight belongs to the list it was chosen in', () => {
  const first = ['Heading', 'Table', 'Divider']
  const held = holdSelection(null, first, (index) => index + 2)
  assertEquals(selectionIn(held, first), 2)
  assertEquals(selectionIn(held, [...first]), 0)
  assertEquals(selectionIn(null, first), 0)
  const narrowed = ['Table']
  assertEquals(holdSelection(held, narrowed, (index) => index).index, 0)
})
