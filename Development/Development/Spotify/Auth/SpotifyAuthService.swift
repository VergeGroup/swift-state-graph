import AuthenticationServices
import CryptoKit
import Foundation
import StateGraph

// MARK: - SpotifyAuthState Entity

final class SpotifyAuthState: Sendable {
  @GraphStored var isAuthenticated: Bool = false
  @GraphStored var accessToken: String? = nil
  @GraphStored var user: SpotifyUser? = nil
  @GraphStored var errorMessage: String? = nil
  @GraphStored var isLoading: Bool = false

  init() {}
}

// MARK: - SpotifyAuthService

@MainActor
final class SpotifyAuthService: NSObject, Sendable {

  // Client ID obtained from Spotify Developer Dashboard
  // Should be retrieved from environment variables or plist in production
  private let clientId = "YOUR_SPOTIFY_CLIENT_ID"
  private let redirectUri = "spotify-auth://callback"
  private let scope = "user-read-private user-read-email playlist-read-private"

  @GraphStored var authState: SpotifyAuthState

  private var codeVerifier: String = ""
  private var codeChallenge: String = ""

  override init() {
    self.authState = SpotifyAuthState()
    super.init()
    generatePKCECodes()
  }

  // Generate PKCE codes
  private func generatePKCECodes() {
    // Code Verifier (43-128 character random string)
    let verifierData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    codeVerifier = verifierData.base64URLEncodedString()

    // Code Challenge (SHA256 hash of Code Verifier, Base64URL encoded)
    let challengeData = Data(SHA256.hash(data: codeVerifier.data(using: .utf8)!))
    codeChallenge = challengeData.base64URLEncodedString()
  }

  // Start Spotify authentication
  func authenticate() {
    guard let url = buildAuthURL() else {
      authState.errorMessage = "Failed to generate authentication URL"
      return
    }

    authState.errorMessage = nil
    authState.isLoading = true

    let session = ASWebAuthenticationSession(
      url: url,
      callbackURLScheme: "spotify-auth"
    ) { [weak self] callbackURL, error in
      Task { @MainActor in
        guard let self = self else { return }

        self.authState.isLoading = false

        if let error = error {
          self.authState.errorMessage = "Authentication error: \(error.localizedDescription)"
          return
        }

        guard let callbackURL = callbackURL else {
          self.authState.errorMessage = "Failed to get callback URL"
          return
        }

        await self.handleCallback(url: callbackURL)
      }
    }

    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    session.start()
  }

  // Build authentication URL
  private func buildAuthURL() -> URL? {
    var components = URLComponents(string: "https://accounts.spotify.com/authorize")
    components?.queryItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectUri),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "scope", value: scope),
      URLQueryItem(name: "state", value: generateRandomState()),
    ]
    return components?.url
  }

  // Generate random state parameter
  private func generateRandomState() -> String {
    let data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    return data.base64URLEncodedString()
  }

  // Handle callback URL
  private func handleCallback(url: URL) async {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    else {
      authState.errorMessage = "Invalid callback URL"
      return
    }

    // Check for errors
    if let error = queryItems.first(where: { $0.name == "error" })?.value {
      authState.errorMessage = "Authentication error: \(error)"
      return
    }

    // Get authorization code
    guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
      authState.errorMessage = "Failed to get authorization code"
      return
    }

    // Exchange code for access token
    await exchangeCodeForToken(code: code)
  }

  // Exchange authorization code for access token
  private func exchangeCodeForToken(code: String) async {
    guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
      authState.errorMessage = "Invalid token endpoint URL"
      return
    }

    authState.isLoading = true

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let bodyData = [
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": redirectUri,
      "client_id": clientId,
      "code_verifier": codeVerifier,
    ]

    let bodyString = bodyData.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    request.httpBody = bodyString.data(using: .utf8)

    do {
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse,
        httpResponse.statusCode == 200
      else {
        authState.isLoading = false
        authState.errorMessage = "Failed to get access token"
        return
      }

      let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
      authState.accessToken = tokenResponse.access_token
      authState.isAuthenticated = true
      authState.isLoading = false
      authState.errorMessage = nil

      // Fetch user profile
      await fetchUserProfile()

    } catch {
      authState.isLoading = false
      authState.errorMessage = "Token exchange error: \(error.localizedDescription)"
    }
  }

  // Fetch user profile
  private func fetchUserProfile() async {
    guard let token = authState.accessToken,
      let url = URL(string: "https://api.spotify.com/v1/me")
    else {
      return
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    do {
      let (data, _) = try await URLSession.shared.data(for: request)
      let userProfile = try JSONDecoder().decode(UserProfile.self, from: data)

      authState.user = SpotifyUser(id: userProfile.id, name: userProfile.display_name ?? "Unknown")

    } catch {
      print("User profile fetch error: \(error)")
    }
  }

  // Logout
  func logout() {
    authState.isAuthenticated = false
    authState.accessToken = nil
    authState.user = nil
    authState.errorMessage = nil
    authState.isLoading = false
    generatePKCECodes()  // Generate new PKCE codes
  }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension SpotifyAuthService: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    ASPresentationAnchor()
  }
}

// MARK: - SpotifyAuthViewModel

@MainActor
final class SpotifyAuthViewModel: ObservableObject {
  let authService: SpotifyAuthService

  @GraphStored var isAuthenticated: Bool
  @GraphStored var user: SpotifyUser?
  @GraphStored var errorMessage: String?
  @GraphStored var isLoading: Bool

  init(authService: SpotifyAuthService = SpotifyAuthService()) {
    self.authService = authService

    self.$isAuthenticated = authService.authState.$isAuthenticated
    self.$user = authService.authState.$user
    self.$errorMessage = authService.authState.$errorMessage
    self.$isLoading = authService.authState.$isLoading
  }

  func authenticate() {
    authService.authenticate()
  }

  func logout() {
    authService.logout()
  }
}

// MARK: - Response Models

private struct TokenResponse: Codable {
  let access_token: String
  let token_type: String
  let scope: String
  let expires_in: Int
  let refresh_token: String?
}

private struct UserProfile: Codable {
  let id: String
  let display_name: String?
  let email: String?
}

// MARK: - Data Extension for Base64URL

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    return base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
