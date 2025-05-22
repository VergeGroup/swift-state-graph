import SwiftUI
import StateGraph

struct MovieDetailView: View {
    let movie: Movie
    @State private var isLoading = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerView
                
                if let posterURL = movie.posterURL {
                    AsyncImage(url: posterURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(height: 300)
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 300)
                        case .failure:
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .frame(height: 300)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                
                Text("Plot")
                    .font(.headline)
                
                Text(movie.plot.isEmpty ? "No plot available" : movie.plot)
                    .font(.body)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle(movie.title)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(movie.title)
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("\(movie.year) • \(movie.type.capitalized)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if movie.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.title2)
            }
        }
    }
}
