import type { DraftFile, FileVault } from './drafts.ts'
import { deleteKeys, objectStore } from '~/sdk/idb'

const databaseName = 'wuhu-drafts'
const storeName = 'files'
const withStore = objectStore(databaseName, storeName)

export const indexedDBVault: FileVault = {
  read: (key) =>
    withStore<DraftFile[] | undefined>('readonly', (store) => store.get(key)),
  write: async (key, files) => {
    await withStore('readwrite', (store) => store.put(files, key))
  },
  remove: async (key) => {
    await withStore('readwrite', (store) => store.delete(key))
  },
  sweep: (keep) =>
    deleteKeys(databaseName, storeName, (key) => keep(String(key))),
}
