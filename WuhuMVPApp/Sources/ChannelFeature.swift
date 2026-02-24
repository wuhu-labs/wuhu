import MarkdownUI
import SwiftUI

// MARK: - Channel Chat View (group chat style)

struct ChannelChatView: View {
  let channel: MockChannel
  var onSend: ((String) -> Void)?
  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text(channel.name)
          .font(.headline)
        Spacer()
        Text("\(channel.messages.count) messages")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.bar)

      Divider()

      // Messages + Input centered
      VStack(spacing: 0) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(channel.messages) { message in
              ChannelMessageRow(
                message: message,
                showAuthor: shouldShowAuthor(for: message),
              )
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }

        Divider()

        HStack(alignment: .bottom, spacing: 8) {
          TextField("Message \(channel.name)...", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 5)
            .padding(10)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onSubmit {
              sendDraft()
            }
          Button {
            sendDraft()
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
      .frame(maxWidth: 800)
    }
  }

  private func sendDraft() {
    guard !draft.isEmpty else { return }
    onSend?(draft)
    draft = ""
  }

  private func shouldShowAuthor(for message: MockChannelMessage) -> Bool {
    guard let index = channel.messages.firstIndex(where: { $0.id == message.id }), index > 0
    else { return true }
    let prev = channel.messages[index - 1]
    return prev.author != message.author
      || message.timestamp.timeIntervalSince(prev.timestamp) > 300
  }
}

// MARK: - Channel Message Row

struct ChannelMessageRow: View {
  let message: MockChannelMessage
  let showAuthor: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if showAuthor {
        avatar.padding(.top, 10)
      } else {
        Spacer().frame(width: 32)
      }

      VStack(alignment: .leading, spacing: 2) {
        if showAuthor {
          HStack(spacing: 6) {
            Text(message.author)
              .font(.callout)
              .fontWeight(.semibold)
              .foregroundStyle(message.isAgent ? .orange : .primary)
            Text(message.timestamp, style: .time)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          .padding(.top, 8)
        }

        Markdown(message.content)
          .textSelection(.enabled)
      }

      Spacer()
    }
  }

  private var avatar: some View {
    Text(String(message.author.prefix(1)).uppercased())
      .font(.caption2)
      .fontWeight(.bold)
      .foregroundStyle(.white)
      .frame(width: 32, height: 32)
      .background(avatarColor)
      .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var avatarColor: Color {
    if message.isAgent { return .orange }
    switch message.author.lowercased() {
    case "minsheng": return .blue
    case "anna": return .purple
    case "yihan": return .green
    case "kesou": return .pink
    default: return .gray
    }
  }
}
