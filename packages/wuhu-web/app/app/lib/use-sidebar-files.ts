import { useEffect, useState } from 'react'
import {
  sidebarDirectory,
  type SidebarFile,
  sidebarFile,
  sidebarName,
  sidebarPaths,
} from './sidebars.ts'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage, isFileRefusal } from '~/sdk/errors'

// A group's sidebar definitions, live: the folder's listing, then each file.
// A group without the folder has none.
export function useSidebarFiles(client: SpaceClient): SidebarFile[] | null {
  const [paths, setPaths] = useState<readonly string[] | null>(null)
  useEffect(
    () =>
      client.list(sidebarDirectory)(
        (listing) => setPaths(sidebarPaths(listing)),
        (failure) => {
          if (isFileRefusal(failure)) setPaths([])
        },
      ),
    [client],
  )
  const [files, setFiles] = useState<SidebarFile[] | null>(null)
  const key = paths?.join('\n') ?? null
  useEffect(() => {
    if (paths === null) return
    const loaded = new Map<string, SidebarFile>()
    const publish = () => {
      if (loaded.size === paths.length) {
        setFiles(paths.map((path) => loaded.get(path)!))
      }
    }
    publish()
    const stops = paths.map((path) =>
      client.read(path)(
        (output) => {
          loaded.set(path, sidebarFile(path, output.content))
          publish()
        },
        (failure) => {
          loaded.set(path, {
            path,
            title: sidebarName(path),
            failure: errorMessage(failure),
          })
          publish()
        },
      )
    )
    return () => {
      for (const stop of stops) stop()
    }
  }, [client, key])
  return files
}
