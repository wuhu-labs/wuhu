import SwiftUI

/// Simple home view placeholder. For MVP, shows a welcome message.
/// Can be replaced with an activity feed in the future.
struct HomeView: View {
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "house")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)

      Text("Welcome to Wuhu")
        .font(.title2)
        .fontWeight(.medium)

      Text("Select Channels, Sessions, Issues, or Docs from the sidebar to get started.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("Home")
  }
}
