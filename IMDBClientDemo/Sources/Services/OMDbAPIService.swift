import Foundation
import StateGraph

enum APIError: Error {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case serverError(Int)
}

struct SearchResponse: Decodable {
    let Search: [MovieResult]?
    let totalResults: String?
    let Response: String
    let Error: String?
    
    struct MovieResult: Decodable {
        let Title: String
        let Year: String
        let imdbID: String
        let `Type`: String
        let Poster: String
    }
}

struct MovieDetailResponse: Decodable {
    let Title: String
    let Year: String
    let Rated: String
    let Released: String
    let Runtime: String
    let Genre: String
    let Director: String
    let Writer: String
    let Actors: String
    let Plot: String
    let Poster: String
    let imdbID: String
    let `Type`: String
    let Response: String
    let Error: String?
}

@MainActor
final class OMDbAPIService {
    private let apiKey = "YOUR_API_KEY" // Replace with a real API key
    private let baseURL = "https://www.omdbapi.com/"
    
    private let store: MovieStore
    
    init(store: MovieStore) {
        self.store = store
    }
    
    func searchMovies(query: String) async {
        guard !query.isEmpty else { return }
        
        store.isLoading = true
        store.error = nil
        
        let urlString = "\(baseURL)?s=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&apikey=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            store.error = APIError.invalidURL
            store.isLoading = false
            return
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                store.error = APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
                store.isLoading = false
                return
            }
            
            let searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
            
            if let searchResults = searchResponse.Search {
                for result in searchResults {
                    let posterURL = result.Poster != "N/A" ? URL(string: result.Poster) : nil
                    let movie = Movie(
                        id: result.imdbID,
                        title: result.Title, 
                        year: result.Year,
                        posterURL: posterURL,
                        imdbID: result.imdbID,
                        type: result.Type
                    )
                    store.movies.add(movie)
                }
            } else if searchResponse.Response == "False" {
                store.error = NSError(domain: "OMDbAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: searchResponse.Error ?? "Unknown error"])
            }
            
            store.isLoading = false
        } catch {
            store.error = APIError.networkError(error)
            store.isLoading = false
        }
    }
}
