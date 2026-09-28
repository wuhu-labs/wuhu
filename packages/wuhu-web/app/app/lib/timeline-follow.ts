export interface ScrollMetrics {
  scrollTop: number
  scrollHeight: number
  clientHeight: number
}

export interface Follow {
  following: boolean
  scrollTop: number
}

const bottomSlackPx = 40

export function atBottom(metrics: ScrollMetrics): boolean {
  return metrics.scrollHeight - metrics.scrollTop - metrics.clientHeight <=
    bottomSlackPx
}

// The pin and the jump-to-latest control both read `following`. Only the
// reader moving up lets go of the latest message: content growing under a
// pinned view, or the scroll event the pin itself raises, keeps it.
export function followAfterScroll(
  previous: Follow,
  metrics: ScrollMetrics,
): Follow {
  return {
    following: atBottom(metrics) ||
      (previous.following && metrics.scrollTop >= previous.scrollTop),
    scrollTop: metrics.scrollTop,
  }
}

// Where a resize of the canvas or its content leaves the view: back on the
// latest message while following, untouched otherwise.
export function scrollAfterResize(
  follow: Follow,
  metrics: ScrollMetrics,
): number | null {
  return follow.following ? metrics.scrollHeight - metrics.clientHeight : null
}

// A toggle the reader makes keeps what they clicked where it was on screen:
// the view lets go of the latest message and moves as far as the clicked line
// moved.
export function holdAnchor(
  scrollTop: number,
  before: number,
  after: number,
): Follow {
  return { following: false, scrollTop: scrollTop + after - before }
}
