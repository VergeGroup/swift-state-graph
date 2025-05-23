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

final class SpotifyStore: Sendable {

  @GraphStored var users: EntityStore<SpotifyUser> = .init()
  @GraphStored var artists: EntityStore<Artist> = .init()
  @GraphStored var tracks: EntityStore<Track> = .init()
  @GraphStored var playlists: EntityStore<Playlist> = .init()
} 