import Foundation
import os
import QuartetEngine

/// Direct client for the Anthropic Messages API (`POST /v1/messages`, streaming SSE).
public struct AnthropicClient: ProviderStreaming {
    static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "anthropic")
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    public init() {}

    public func stream(request: SeatRequest, apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<StreamChunk, Error>.makeStream()
        let task = Task {
            do {
                let urlRequest = try Self.makeURLRequest(request: request, apiKey: apiKey)
                let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                try await StreamingHTTP.validate(bytes: bytes, response: response, logger: Self.logger)

                var splitter = SSELineSplitter()
                var parser = SSEParser()
                var decoder = AnthropicSSEDecoder()

                for try await byte in bytes {
                    guard let line = splitter.feed(byte) else { continue }
                    guard let event = parser.feed(line: line) else { continue }
                    for chunk in try decoder.decode(event) {
                        continuation.yield(chunk)
                    }
                    if decoder.sawTerminal { break }
                }

                guard decoder.sawTerminal else {
                    throw ProviderError.truncatedStream(provider: "Anthropic")
                }
                continuation.finish()
            } catch {
                Self.logger.error("Anthropic stream failed: \(String(describing: error), privacy: .public)")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Request building

    struct RequestBody: Encodable {
        var model: String
        var max_tokens: Int
        var stream: Bool
        var system: String?
        var messages: [Message]

        struct Message: Encodable {
            var role: String
            var content: [Content]
        }

        enum Content: Encodable {
            case text(String)
            case image(mediaType: String, base64: String)

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: DynamicKey.self)
                switch self {
                case .text(let text):
                    try container.encode("text", forKey: DynamicKey("type"))
                    try container.encode(text, forKey: DynamicKey("text"))
                case .image(let mediaType, let base64):
                    try container.encode("image", forKey: DynamicKey("type"))
                    var source = container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("source"))
                    try source.encode("base64", forKey: DynamicKey("type"))
                    try source.encode(mediaType, forKey: DynamicKey("media_type"))
                    try source.encode(base64, forKey: DynamicKey("data"))
                }
            }
        }
    }

    static func makeURLRequest(request: SeatRequest, apiKey: String) throws -> URLRequest {
        // Anthropic takes system prompts as a top-level field, not a message role.
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.text)
            .joined(separator: "\n\n")

        let wireMessages: [RequestBody.Message] = request.messages
            .filter { $0.role != .system }
            .map { message in
                var content: [RequestBody.Content] = []
                for image in message.images {
                    content.append(.image(mediaType: image.mediaType, base64: image.base64Data))
                }
                content.append(.text(message.text))
                return RequestBody.Message(role: message.role.rawValue, content: content)
            }

        let body = RequestBody(model: request.seat.modelID,
                               max_tokens: request.maxTokens,
                               stream: true,
                               system: systemText.isEmpty ? nil : systemText,
                               messages: wireMessages)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120 // idle timeout between bytes, not total duration
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }
}

/// Minimal string-keyed CodingKey for hand-rolled wire shapes.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Shared HTTP status validation for streaming responses.
enum StreamingHTTP {
    /// Throws ProviderError.http with (up to 16KB of) the error body on non-2xx.
    static func validate(bytes: URLSession.AsyncBytes, response: URLResponse, logger: Logger) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 16_384 { break }
                }
            } catch {
                logger.error("Failed reading error body for HTTP \(http.statusCode): \(String(describing: error), privacy: .public)")
            }
            throw ProviderError.http(status: http.statusCode, body: String(decoding: body, as: UTF8.self))
        }
    }
}
