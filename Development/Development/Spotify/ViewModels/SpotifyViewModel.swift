import Foundation
import StateGraph
import SwiftUI

// MARK: - ViewModel

@MainActor
final class SpotifyViewModel: ObservableObject {
  @GraphStored var store: SpotifyStore
  @GraphComputed var playlists: [Playlist]

  let service: SpotifyService

  init(store: SpotifyStore) {
    self.store = store
    self.service = .init(store: store)

    self.$playlists = store.$playlists.map { _, value in
      value.getAll().sorted { $0.name < $1.name }
    }
  }

  func load() {
    service.loadSampleData()
  }
} 