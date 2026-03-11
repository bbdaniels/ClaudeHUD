import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "APIClient")

// MARK: - Errors

enum ClaudeAPIClientError: LocalizedError {
    case noAPIKey
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Add your Anthropic API key in Settings."
        case .httpError(let code, let message):
            return "API error (\(code)): \(message)"
        case .decodingError(let error):
            return "Failed to decode API response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Client

@MainActor
class ClaudeAPIClient: ObservableObject {
    @Published var isLoading = false

    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"
    private var apiKey: String?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    // MARK: - Configuration

    func setAPIKey(_ key: String) {
        self.apiKey = key
    }

    // MARK: - Send

    /// Send a request to the Anthropic Messages API and return the parsed response.
    func sendMessage(request: ClaudeRequest) async throws -> ClaudeResponse {
        guard let apiKey, !apiKey.isEmpty else {
            throw ClaudeAPIClientError.noAPIKey
        }

        // Build the URLRequest
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            let body = try encoder.encode(request)
            urlRequest.httpBody = body

            #if DEBUG
            if let bodyString = String(data: body, encoding: .utf8) {
                logger.debug("Request body (\(body.count) bytes): \(bodyString.prefix(2000))")
            }
            #endif
        } catch {
            logger.error("Failed to encode request: \(error.localizedDescription)")
            throw ClaudeAPIClientError.decodingError(error)
        }

        isLoading = true
        defer { isLoading = false }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            logger.error("Network request failed: \(error.localizedDescription)")
            throw ClaudeAPIClientError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIClientError.networkError(
                NSError(domain: "ClaudeAPIClient", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid response type"])
            )
        }

        #if DEBUG
        if let responseString = String(data: data, encoding: .utf8) {
            logger.debug("Response (\(httpResponse.statusCode)): \(responseString.prefix(2000))")
        }
        #endif

        // Handle non-success status codes
        guard (200...299).contains(httpResponse.statusCode) else {
            let message: String
            if let apiError = try? decoder.decode(ClaudeAPIError.self, from: data) {
                message = apiError.error.message
            } else if let raw = String(data: data, encoding: .utf8) {
                message = raw.prefix(500).description
            } else {
                message = "Unknown error"
            }
            logger.error("API error \(httpResponse.statusCode): \(message)")
            throw ClaudeAPIClientError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        // Decode the successful response
        do {
            let claudeResponse = try decoder.decode(ClaudeResponse.self, from: data)
            logger.info(
                "Response received: \(claudeResponse.usage.inputTokens) in / \(claudeResponse.usage.outputTokens) out tokens, stop_reason=\(claudeResponse.stopReason ?? "nil")"
            )
            return claudeResponse
        } catch {
            logger.error("Failed to decode response: \(error)")
            #if DEBUG
            if let raw = String(data: data, encoding: .utf8) {
                logger.debug("Raw response for debugging: \(raw.prefix(2000))")
            }
            #endif
            throw ClaudeAPIClientError.decodingError(error)
        }
    }
}
