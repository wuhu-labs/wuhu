import type { PathMap } from './tree'
import { kept } from './cached-then-live'
import { coalescedRefresh } from '~/sdk/coalesced-refresh'

export interface TreeSnapshot {
  paths: PathMap
  rev: number
}

export interface DiscoveredTree extends TreeSnapshot {
  from: number | null
  error: string | null
}

export class TreeDiscovery {
  private tree: DiscoveredTree = {
    paths: new Map(),
    rev: 0,
    from: null,
    error: null,
  }
  private refresh: ReturnType<typeof coalescedRefresh<TreeSnapshot>> | undefined

  constructor(
    private readonly source: {
      kept(): Promise<TreeSnapshot | undefined>
      load(): Promise<TreeSnapshot>
    },
    private readonly publish: (tree: DiscoveredTree) => void,
  ) {}

  restore(): Promise<void> {
    this.close()
    this.refresh = coalescedRefresh(
      () =>
        this.tree.from !== null
          ? Promise.resolve(this.tree)
          : kept(this.source.kept()).catch(() => this.source.load()),
      (tree) => {
        this.tree = { ...tree, from: tree.rev, error: null }
        this.publish(this.tree)
      },
      (failure) => {
        this.tree = { ...this.tree, error: String(failure) }
        this.publish(this.tree)
      },
    )
    return this.refresh.run()
  }

  readonly opened = (): void => {
    if (this.tree.from === null) void this.refresh?.run()
  }

  close(): void {
    this.refresh?.close()
    this.refresh = undefined
  }
}
