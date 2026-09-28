export type StoreOperation = <Output>(
  mode: IDBTransactionMode,
  operate: (store: IDBObjectStore) => IDBRequest<Output>,
) => Promise<Output>

function openDatabase(
  databaseName: string,
  storeName: string,
): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1)
    request.onupgradeneeded = () => request.result.createObjectStore(storeName)
    request.onsuccess = () => resolve(request.result)
    request.onerror = () =>
      reject(request.error ?? new Error('indexedDB open failed'))
  })
}

// One object store in its own database, opened per request and closed after.
export function objectStore(
  databaseName: string,
  storeName: string,
): StoreOperation {
  return async (mode, operate) => {
    const database = await openDatabase(databaseName, storeName)
    try {
      return await new Promise((resolve, reject) => {
        const request = operate(
          database.transaction(storeName, mode).objectStore(storeName),
        )
        request.onsuccess = () => resolve(request.result)
        request.onerror = () =>
          reject(request.error ?? new Error('indexedDB request failed'))
      })
    } finally {
      database.close()
    }
  }
}

// Walks the store's keys in one transaction, deleting each one `keep` refuses.
export async function deleteKeys(
  databaseName: string,
  storeName: string,
  keep: (key: IDBValidKey) => boolean,
): Promise<void> {
  const database = await openDatabase(databaseName, storeName)
  try {
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction(storeName, 'readwrite')
      const store = transaction.objectStore(storeName)
      store.openKeyCursor().onsuccess = (event) => {
        const cursor = (event.target as IDBRequest<IDBCursor | null>).result
        if (cursor === null) return
        if (!keep(cursor.primaryKey)) store.delete(cursor.primaryKey)
        cursor.continue()
      }
      transaction.oncomplete = () => resolve()
      transaction.onerror = () =>
        reject(transaction.error ?? new Error('indexedDB sweep failed'))
    })
  } finally {
    database.close()
  }
}
