import Foundation
import os
import QuartetEngine

/// Client for OpenAI-chat-compatible streaming endpoints. Used for both
/// OpenAI (api.openai.com) and OpenRouter (openrouter.ai) — same SSE shape,
/// different base URL / auth header quirks / max-token field name.
public struct OpenAIChatClient: ProviderStreaming {
    static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "openai-compat")

    public enum Flavor: Sendable {
        case openAI
        case openRouter

        var endpoint: URL {
            switch self {
            case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
            case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            }
        }

        var displayName: String {
            switch self {
            case .openAI: return "OpenAI"
            case .openRouter: return "OpenRouter"
            }
        }

        /// OpenAI's newer models reject `max_tokens` in favor of
        /// `max_completion_tokens`; OpenRouter normalizes on `max_tokens`.
        var maxTokensField: String {
            switch self {
            case .openAI: return "max_completion_tokens"
            case .openRouter: return "max_tokens"
            }
        }
    }

    let flavor: Flavor

    public init(flavor: Flavor) {
        self.flavor = flavor
    }

    public func stream(request: SeatRequest, apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<StreamChunk, Error>.makeStream()
        let flavor = self.flavor
        let task = Task {
            do {
                let urlRequest = try Self.makeURLRequest(request: request, apiKey: apiKey, flavor: flavor)
                let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                try await StreamingHTTP.validate(bytes: bytes, response: response, logger: Self.logger)

                var splitter = SSELineSplitter()
                var parser = SSEParser()
                var decoder = OpenAIChatSSEDecoder()

                for try await byte in bytes {
                    guard let line = splitter.feed(byte) else { continue }
                    guard let event = parser.feed(line: line) else { continue }
                    for chunk in try decoder.decode(event) {
                        continuation.yield(chunk)
                    }
                    if decoder.sawTerminal { break }
                }

                guard decoder.sawTerminal else {
                    throw ProviderError.truncatedStream(provider: flavor.displayName)
                }
                continuation.finish()
            } catch {
                Self.logger.error("\(flavor.displayName, privacy: .public) stream failed: \(String(describing: error), privacy: .public)")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Request building

    static func makeURLRequest(request: SeatRequest, apiKey: String, flavor: Flavor) throws -> URLRequest {
        var messages: [[String: Any]] = []
        for message in request.messages {
            if message.role == .system {
                messages.append(["role": "system", "content": message.text])
                continue
            }
            var parts: [[String: Any]] = []
            for image in message.images {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64Data)"],
                ])
            }
            parts.append(["type": "text", "text": message.text])
            messages.append(["role": message.role.rawValue, "content": parts])
        }

        var body: [String: Any] = [
            "model": request.seat.modelID,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages,
        ]
        body[flavor.maxTokensField] = request.maxTokens

        var urlRequest = URLRequest(url: flavor.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if case .openRouter = flavor {
            // Optional attribution headers OpenRouter asks nicely for.
            urlRequest.setValue("QuartetDesk", forHTTPHeaderField: "X-Title")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}

/// Default resolver: keys come from the macOS Keychain, clients by provider kind.
public struct KeychainProviderResolver: ProviderResolving {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    public func client(for seat: Seat) throws -> any ProviderStreaming {
        switch seat.provider {
        case .anthropic: return AnthropicClient()
        case .openai: return OpenAIChatClient(flavor: .openAI)
        case .openrouter: return OpenAIChatClient(flavor: .openRouter)
        }
    }

    public func apiKey(for provider: ProviderKind) throws -> String {
        guard let key = try keychain.key(for: provider),
              !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProviderError.missingAPIKey(provider)
        }
        return key
    }
}
