import SwiftUI

extension View {
  @ViewBuilder
  func wuhuTextInputAutocapitalizationNever() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.never)
    #else
      self
    #endif
  }

  @ViewBuilder
  func wuhuTextInputAutocapitalizationSentences() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.sentences)
    #else
      self
    #endif
  }

  @ViewBuilder
  func wuhuAutocorrectionDisabled() -> some View {
    #if os(iOS)
      autocorrectionDisabled()
    #else
      self
    #endif
  }

  @ViewBuilder
  func wuhuKeyboardTypeURL() -> some View {
    #if os(iOS)
      keyboardType(.URL)
    #else
      self
    #endif
  }

  @ViewBuilder
  func wuhuNavigationBarTitleDisplayModeInline() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
}
