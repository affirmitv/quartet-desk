import Foundation
import os
import QuartetEngine

/// Cheap live validation for the Settings "Test" buttons.
/// Uses list/introspection endpoints (no token spend):
/// - Anthropic:   GET https://api.anthropic.com/v1/models
/// - OpenAI:      GET https://api.openai.com/v1/models
/// - OpenRouter:  GET https://openrouter.ai/api/v1/key   (authenticated key info)
public struct KeyTester: Sendable {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "keytester")

    public init() {}

    /// Returns a short human-readable success summary, or throws.
    public func test(provider: ProviderKind, apiKey: String) async throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.missingAPIKey(provider) }

        var request: URLRequest
        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        case .openrouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            Self.logger.error("Key test failed for \(provider.rawValue, privacy: .public): HTTP \(http.statusCode)")
            throw ProviderError.http(status: http.statusCode, body: body)
        }

        switch provider {
        case .anthropic, .openai:
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = object["data"] as? [[String: Any]] {
                return "Key valid — \(models.count) models visible."
            }
            return "Key valid (HTTP \(http.statusCode))."
        case .openrouter:
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let info = object["data"] as? [String: Any],
               let label = info["label"] as? String {
                return "Key valid — \(label)."
            }
            return "Key valid (HTTP \(http.statusCode))."
        }
    }
}
