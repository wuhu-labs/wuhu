import { kept } from './cached-then-live'
import { coalescedRefresh } from '~/sdk/coalesced-refresh'

// Where a group's change feed starts: the revision it last reached, kept,
// else the head the server reports. Until either is known the feed starts at
// the latest change, and its first open asks again.
export interface FeedStart {
  from: number | null
  error: string | null
}

export class FeedStartDiscovery {
  private start: FeedStart = { from: null, error: null }
  private refresh: ReturnType<typeof coalescedRefresh<number>> | undefined

  constructor(
    private readonly source: {
      kept(): Promise<number | undefined>
      load(): Promise<number>
    },
    private readonly publish: (start: FeedStart) => void,
  ) {}

  restore(): Promise<void> {
    this.close()
    this.refresh = coalescedRefresh(
      () =>
        this.start.from !== null
          ? Promise.resolve(this.start.from)
          : kept(this.source.kept()).catch(() => this.source.load()),
      (rev) => {
        this.start = { from: rev, error: null }
        this.publish(this.start)
      },
      (failure) => {
        this.start = { ...this.start, error: String(failure) }
        this.publish(this.start)
      },
    )
    return this.refresh.run()
  }

  readonly opened = (): void => {
    if (this.start.from === null) void this.refresh?.run()
  }

  close(): void {
    this.refresh?.close()
    this.refresh = undefined
  }
}
