import SwiftUI

struct SpotifyLoginView: View {
    @StateObject private var viewModel = SpotifyAuthViewModel()
    
    var body: some View {
        NavigationView {
            ZStack {
                // Gradient background
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.11, green: 0.73, blue: 0.33), // Spotify Green
                        Color.black
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 40) {
                    Spacer()
                    
                    // Spotify logo area
                    VStack(spacing: 20) {
                        Image(systemName: "music.note")
                            .font(.system(size: 80, weight: .light))
                            .foregroundColor(.white)
                        
                        Text("Spotify")
                            .font(.system(size: 48, weight: .bold, design: .default))
                            .foregroundColor(.white)
                    }
                    
                    Spacer()
                    
                    // Content based on authentication state
                    if viewModel.isAuthenticated {
                        authenticatedContent
                    } else {
                        unauthenticatedContent
                    }
                    
                    // Error message
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 32)
                
                // Loading indicator
                if viewModel.isLoading {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .overlay(
                            VStack(spacing: 20) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)
                                
                                Text("認証中...")
                                    .font(.headline)
                                    .foregroundColor(.white)
                            }
                        )
                }
            }
        }
    }
    
    // Content for unauthenticated state
    private var unauthenticatedContent: some View {
        VStack(spacing: 24) {
            Text("音楽をもっと楽しく")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            
            Text("Spotifyアカウントでログインして、\nあなたの音楽ライブラリにアクセスしましょう")
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            
            Button(action: {
                viewModel.authenticate()
            }) {
                HStack {
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .medium))
                    
                    Text("Spotifyでログイン")
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.white)
                .cornerRadius(28)
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(viewModel.isLoading)
        }
    }
    
    // Content for authenticated state
    private var authenticatedContent: some View {
        VStack(spacing: 24) {
            // User information
            VStack(spacing: 12) {
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                    )
                
                if let user = viewModel.user {
                    Text("ようこそ、\(user.name)さん")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                } else {
                    Text("ログイン完了")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                
                Text("Spotifyアカウントに正常にログインしました")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            
            // Action buttons
            VStack(spacing: 12) {
                NavigationLink(destination: SpotifyListView()) {
                    HStack {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .medium))
                        
                        Text("プレイリストを表示")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white)
                    .cornerRadius(24)
                }
                .buttonStyle(ScaleButtonStyle())
                
                Button(action: {
                    viewModel.logout()
                }) {
                    Text("ログアウト")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(24)
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
    }
}

// Custom button style
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    SpotifyLoginView()
} 