import SwiftUI
import StateGraph
import StateGraphNormalization

// MARK: - Spotify Entities

final class SpotifyUser: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID

  @GraphStored var name: String

  init(id: String, name: String) {
    self.typedID = .init(id)
    self.name = name
  }
}

final class Track: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID

  @GraphStored var title: String
  @GraphStored var artist: Artist

  init(id: String, title: String, artist: Artist) {
    self.typedID = .init(id)
    self.title = title
    self.artist = artist
  }
}

final class Artist: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID

  @GraphStored var name: String

  init(id: String, name: String) {
    self.typedID = .init(id)
    self.name = name
  }
}

final class Playlist: TypedIdentifiable, Sendable {
  typealias TypedIdentifierRawValue = String
  let typedID: TypedID

  @GraphStored var name: String
  @GraphComputed var tracks: [Track]
  unowned let owner: SpotifyUser

  init(id: String, name: String, owner: SpotifyUser, store: SpotifyStore) {
    self.typedID = .init(id)
    self.name = name
    self.owner = owner
    self.$tracks = .init { context in
      store.tracks.filter { $0.artist.typedID.raw == $0.artist.id.raw }
    }
  }
}

// MARK: - Store

final class SpotifyStore: ComputedEnvironmentKey, Sendable {
  typealias Value = SpotifyStore

  @GraphStored var users: EntityStore<SpotifyUser> = .init()
  @GraphStored var artists: EntityStore<Artist> = .init()
  @GraphStored var tracks: EntityStore<Track> = .init()
  @GraphStored var playlists: EntityStore<Playlist> = .init()
}

// MARK: - Service (Stub)

@MainActor
final class SpotifyService {
  private let store: SpotifyStore

  init(store: SpotifyStore) {
    self.store = store
  }

  func loadSampleData() {
    let artist = Artist(id: "artist1", name: "Sample Artist")
    store.artists.add(artist)

    let user = SpotifyUser(id: "user1", name: "Listener")
    store.users.add(user)

    let track = Track(id: "track1", title: "Demo Song", artist: artist)
    store.tracks.add(track)

    let playlist = Playlist(id: "playlist1", name: "My Playlist", owner: user, store: store)
    store.playlists.add(playlist)
  }
}

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

// MARK: - Views

struct SpotifyListView: View {
  @StateObject var viewModel: SpotifyViewModel = .init(store: .init())

  var body: some View {
    VStack {
      List(viewModel.playlists, id: \.id) { playlist in
        Text(playlist.name)
      }
      .onAppear {
        StateGraphGlobal.computedEnvironmentValues.withLock {
          $0[SpotifyStore.self] = viewModel.store
        }
        viewModel.load()
      }
      .onDisappear {
        StateGraphGlobal.computedEnvironmentValues.withLock {
          $0[SpotifyStore.self] = nil
        }
      }
    }
  }
}

#if DEBUG
#Preview("SpotifyClient") {
  SpotifyListView()
}
#endif

