import SwiftUI
import StateGraph

struct SpotifyListView: View {
  @StateObject private var viewModel = SpotifyViewModel(store: SpotifyStore())

  var body: some View {
    NavigationView {
      List(viewModel.playlists) { playlist in
        VStack(alignment: .leading, spacing: 4) {
          Text(playlist.name)
            .font(.headline)
          Text("Owner: \(playlist.owner.name)")
            .font(.caption)
            .foregroundColor(.secondary)
          Text("Tracks: \(playlist.tracks.count)")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
      }
      .navigationTitle("Playlists")
      .onAppear {
        viewModel.load()
      }
    }
  }
} 