import ComposableArchitecture
import SwiftUI

@Reducer
struct HomeFeature {
  @ObservableState
  struct State {
    var events: [MockActivityEvent] = MockData.activityFeed
    var selectedEventID: String?
  }

  enum Action {
    case eventSelected(String?)
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .eventSelected(id):
        state.selectedEventID = id
        return .none
      }
    }
  }
}

// MARK: - Home List (content column)

struct HomeListView: View {
  @Bindable var store: StoreOf<HomeFeature>

  var body: some View {
    List(store.events, selection: $store.selectedEventID.sending(\.eventSelected)) { event in
      HStack(spacing: 10) {
        Image(systemName: event.icon)
          .font(.body)
          .foregroundStyle(.orange)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
          Text(event.description)
            .font(.callout)
            .lineLimit(2)
          Text(event.timestamp, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
      .tag(event.id)
    }
    .listStyle(.inset)
    .navigationTitle("Home")
  }
}

// MARK: - Home Detail (detail column)

struct HomeDetailView: View {
  let store: StoreOf<HomeFeature>

  var body: some View {
    if let eventID = store.selectedEventID,
      let event = store.events.first(where: { $0.id == eventID })
    {
      VStack(spacing: 16) {
        Image(systemName: event.icon)
          .font(.largeTitle)
          .foregroundStyle(.orange)
        Text(event.description)
          .font(.title3)
        Text(event.timestamp, style: .relative)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "Activity Feed",
        systemImage: "house",
        description: Text("Select an event to see details")
      )
    }
  }
}
