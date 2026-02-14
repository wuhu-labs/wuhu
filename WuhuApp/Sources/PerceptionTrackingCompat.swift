import ComposableArchitecture
import SwiftUI

@ViewBuilder
func WuhuPerceptionTracking(@ViewBuilder _ content: @escaping () -> some View) -> some View {
  #if os(macOS)
    content()
  #else
    WithPerceptionTracking {
      content()
    }
  #endif
}
