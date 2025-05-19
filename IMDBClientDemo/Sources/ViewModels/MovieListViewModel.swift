import Foundation
import StateGraph
import SwiftUI

@MainActor
final class MovieListViewModel: ObservableObject {
    @GraphStored
    var store: MovieStore
    
    @GraphComputed
    var searchResults: [Movie]
    
    @GraphComputed
    var favoriteMovies: [Movie]
    
    @GraphComputed
    var isLoading: Bool
    
    @GraphComputed
    var error: Error?
    
    let apiService: OMDbAPIService
    
    init(store: MovieStore) {
        self.store = store
        self.apiService = OMDbAPIService(store: store)
        
        self.$searchResults = store.$movies.map { _, value in
            value.getAll().sorted(by: { $0.title < $1.title })
        }
        
        self.$favoriteMovies = store.$movies.map { _, value in
            value.getAll().filter { $0.isFavorite }.sorted(by: { $0.title < $1.title })
        }
        
        self.$isLoading = store.$isLoading.map { _, value in value }
        
        self.$error = store.$error.map { _, value in value }
    }
    
    func search(query: String) {
        store.searchQuery = query
        Task {
            await apiService.searchMovies(query: query)
        }
    }
    
    func toggleFavorite(for movie: Movie) {
        movie.isFavorite.toggle()
    }
}
