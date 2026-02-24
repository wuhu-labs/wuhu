import SwiftUI

/// A multi-line chat input field that sends on ⌘Enter and inserts newlines on
/// bare Enter. Always shows at least 3 lines of height with a placeholder
/// overlay when the draft is empty.
struct ChatInputField: View {
  @Binding var draft: String
  var placeholder: String = "Message..."
  var onSend: () -> Void

  /// Approximate height of a single line of body text.
  private let lineHeight: CGFloat = 20
  /// Minimum visible lines when the field is empty.
  private let minLines = 3
  /// Maximum lines before the editor stops growing.
  private let maxLines = 10

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      ZStack(alignment: .topLeading) {
        TextEditor(text: $draft)
          .font(.body)
          .scrollContentBackground(.hidden)
          .frame(
            minHeight: lineHeight * CGFloat(minLines),
            maxHeight: lineHeight * CGFloat(maxLines),
          )
          .fixedSize(horizontal: false, vertical: true)
          .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) {
              onSend()
              return .handled
            }
            return .ignored
          }

        // Placeholder overlay
        if draft.isEmpty {
          Text("⌘Enter to send · Enter for newline")
            .foregroundStyle(.tertiary)
            .font(.body)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
        }
      }
      .padding(6)
      .background(.background.secondary)
      .clipShape(RoundedRectangle(cornerRadius: 8))

      Button {
        onSend()
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
          .foregroundStyle(draft.isEmpty ? .gray : .orange)
      }
      .buttonStyle(.plain)
      .disabled(draft.isEmpty)
    }
    .padding(12)
  }
}
