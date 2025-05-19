import SwiftUI
import StateGraph

struct MovieListView: View {
    @StateObject var viewModel: MovieListViewModel
    @State private var searchText: String = ""
    @State private var showFavorites: Bool = false
    
    init(viewModel: MovieListViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    var body: some View {
        NavigationView {
            VStack {
                searchBar
                
                if viewModel.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.error {
                    errorView(error: error)
                } else {
                    movieList
                }
            }
            .navigationTitle("IMDB Client")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(showFavorites ? "All Movies" : "Favorites") {
                        showFavorites.toggle()
                    }
                }
            }
        }
    }
    
    private var searchBar: some View {
        HStack {
            TextField("Search movies...", text: $searchText)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .padding(.horizontal)
            
            Button("Search") {
                viewModel.search(query: searchText)
            }
            .padding(.trailing)
            .disabled(searchText.isEmpty)
        }
        .padding(.vertical, 8)
    }
    
    private var movieList: some View {
        List {
            ForEach(showFavorites ? viewModel.favoriteMovies : viewModel.searchResults) { movie in
                NavigationLink(destination: MovieDetailView(movie: movie)) {
                    MovieCell(movie: movie, onFavoriteToggle: {
                        viewModel.toggleFavorite(for: movie)
                    })
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private func errorView(error: Error) -> some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
                .padding()
            
            Text("Error: \(error.localizedDescription)")
                .multilineTextAlignment(.center)
                .padding()
            
            Button("Try Again") {
                viewModel.search(query: searchText)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MovieCell: View {
    let movie: Movie
    let onFavoriteToggle: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(movie.title)
                    .font(.headline)
                
                Text(movie.year)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onFavoriteToggle) {
                Image(systemName: movie.isFavorite ? "star.fill" : "star")
                    .foregroundColor(movie.isFavorite ? .yellow : .gray)
                    .font(.title2)
            }
        }
        .padding(.vertical, 8)
    }
}
