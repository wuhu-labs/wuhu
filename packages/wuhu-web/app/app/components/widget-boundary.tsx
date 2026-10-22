import { CatalogError } from '@wuhu/ui'
import { Component, type ReactNode } from 'react'

// A widget whose card throws while drawing (a mark fed a shape it cannot
// draw) shows its error card; the rest of the page draws on.
export class WidgetBoundary extends Component<
  { src: string; children: ReactNode },
  { failed: string | null }
> {
  override state = { failed: null as string | null }

  static getDerivedStateFromError(error: unknown) {
    return { failed: error instanceof Error ? error.message : String(error) }
  }

  override render() {
    return this.state.failed == null
      ? this.props.children
      : <CatalogError message={`${this.props.src}: ${this.state.failed}`} />
  }
}
