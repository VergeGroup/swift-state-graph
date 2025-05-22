import Foundation
import StateGraph
import StateGraphNormalization

final class Movie: TypedIdentifiable, Sendable {
    typealias TypedIdentifierRawValue = String
    
    let typedID: TypedID
    
    @GraphStored
    var title: String
    
    @GraphStored
    var year: String
    
    @GraphStored
    var posterURL: URL?
    
    @GraphStored
    var imdbID: String
    
    @GraphStored
    var type: String
    
    @GraphStored
    var plot: String = ""
    
    @GraphStored
    var isFavorite: Bool = false
    
    init(id: String, title: String, year: String, posterURL: URL?, imdbID: String, type: String) {
        self.typedID = .init(id)
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.imdbID = imdbID
        self.type = type
    }
}
