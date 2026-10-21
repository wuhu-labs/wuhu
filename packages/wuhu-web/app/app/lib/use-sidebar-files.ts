import { useEffect, useState } from 'react'
import { type SidebarFile, sidebarFile, sidebarName } from './sidebars.ts'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'

export function useSidebarFiles(
  client: SpaceClient,
  paths: readonly string[],
): SidebarFile[] | null {
  const [files, setFiles] = useState<SidebarFile[] | null>(null)
  const key = paths.join('\n')
  useEffect(() => {
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
