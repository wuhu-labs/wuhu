import { assertEquals } from 'jsr:@std/assert@1'
import {
  draftKey,
  draftLifetimeMs,
  Drafts,
  restoreDraft,
  withDictation,
} from './drafts.ts'

class MemoryStorage implements Storage {
  private items = new Map<string, string>()
  get length() {
    return this.items.size
  }
  clear() {
    this.items.clear()
  }
  getItem(key: string) {
    return this.items.get(key) ?? null
  }
  key(index: number) {
    return [...this.items.keys()][index] ?? null
  }
  removeItem(key: string) {
    this.items.delete(key)
  }
  setItem(key: string, value: string) {
    this.items.set(key, value)
  }
}

Deno.test('a draft survives a new Drafts on the same shelf', () => {
  const shelf = new MemoryStorage()
  new Drafts('me:space', shelf, () => 0).set('session:a', 'hello')
  assertEquals(new Drafts('me:space', shelf, () => 1).get('session:a'), 'hello')
  assertEquals(new Drafts('you:space', shelf, () => 1).get('session:a'), '')
})

Deno.test('taking a draft empties it on the shelf too', () => {
  const shelf = new MemoryStorage()
  const drafts = new Drafts('me:space', shelf, () => 0)
  drafts.set('session:a', 'hello')
  assertEquals(drafts.take('session:a'), 'hello')
  assertEquals(shelf.getItem(draftKey('me:space', 'session:a')), null)
})

Deno.test('a week-old draft is gone and swept', () => {
  const shelf = new MemoryStorage()
  new Drafts('me:space', shelf, () => 0).set('session:a', 'old')
  const later = new Drafts('me:space', shelf, () => draftLifetimeMs + 1)
  assertEquals(later.get('session:a'), '')
  later.sweep()
  assertEquals(shelf.length, 0)
})

Deno.test('dictation appends after a space; a failed send goes back in front', () => {
  assertEquals(withDictation('', ' hi '), 'hi')
  assertEquals(withDictation('so ', 'hi'), 'so hi')
  assertEquals(restoreDraft('sent', ''), 'sent')
  assertEquals(restoreDraft('sent ', 'new'), 'sent\nnew')
})
