import Foundation
import StateGraph

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