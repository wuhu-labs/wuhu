import { useEffect, useState } from 'react'
import { cachedThenLive } from './cached-then-live.ts'
import { type SidebarFile, sidebarFile, sidebarName } from './sidebars.ts'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'

export function useSidebarFiles(
  client: SpaceClient,
  paths: readonly string[],
  rev: number,
): SidebarFile[] | null {
  const [files, setFiles] = useState<SidebarFile[] | null>(null)
  const key = `${rev}\n${paths.join('\n')}`
  useEffect(() => {
    let cancelled = false
    cachedThenLive(
      () =>
        Promise.all(
          paths.map((path) =>
            client.keptRead(path).then((output) =>
              sidebarFile(path, output.content)
            )
          ),
        ),
      // A live pass that reached no file at all leaves the kept paint, or
      // reports its failure when nothing was kept.
      async () => {
        const reads = await Promise.allSettled(
          paths.map((path) => client.read(path)),
        )
        const reached = reads.some((read) => read.status === 'fulfilled')
        if (!reached && reads[0]?.status === 'rejected') throw reads[0].reason
        return reads.map((read, index): SidebarFile =>
          read.status === 'fulfilled'
            ? sidebarFile(paths[index]!, read.value.content)
            : {
              path: paths[index]!,
              title: sidebarName(paths[index]!),
              failure: errorMessage(read.reason),
            }
        )
      },
      (loaded) => {
        if (!cancelled) setFiles(loaded)
      },
      (failure) => {
        if (cancelled) return
        setFiles(paths.map((path) => ({
          path,
          title: sidebarName(path),
          failure: errorMessage(failure),
        })))
      },
    )
    return () => {
      cancelled = true
    }
  }, [client, key])
  return files
}
