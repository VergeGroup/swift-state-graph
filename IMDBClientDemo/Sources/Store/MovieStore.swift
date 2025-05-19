import Foundation
import StateGraph
import StateGraphNormalization

final class MovieStore: ComputedEnvironmentKey, Sendable {
    typealias Value = MovieStore
    
    @GraphStored
    var movies: EntityStore<Movie> = .init()
    
    @GraphStored
    var searchQuery: String = ""
    
    @GraphStored
    var isLoading: Bool = false
    
    @GraphStored
    var error: Error? = nil
}
