import SwiftUI
import StateGraph

@main
struct IMDBClientApp: App {
    @StateObject private var viewModel: MovieListViewModel
    
    init() {
        let store = MovieStore()
        
        StateGraphGlobal.computedEnvironmentValues.withLock {
            $0[MovieStore.self] = store
        }
        
        _viewModel = StateObject(wrappedValue: MovieListViewModel(store: store))
    }
    
    var body: some Scene {
        WindowGroup {
            MovieListView(viewModel: viewModel)
                .onDisappear {
                    StateGraphGlobal.computedEnvironmentValues.withLock {
                        $0[MovieStore.self] = nil
                    }
                }
        }
    }
}
