import ComposableArchitecture
import SwiftUI

@ViewBuilder
func WuhuPerceptionTracking<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
  #if os(macOS)
    content()
  #else
    WithPerceptionTracking {
      content()
    }
  #endif
}
