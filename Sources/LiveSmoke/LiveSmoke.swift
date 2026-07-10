import Foundation
import QuartetEngine
import QuartetProviders

/// Live wire smoke test: streams one tiny completion per configured seat using
/// the REAL provider clients + Keychain keys (service tv.affirmi.quartetdesk).
///
/// Run: `swift run LiveSmoke`
/// Exit 0 = every seat that has a stored key passed; nonzero otherwise.
///
/// This intentionally spends a few real tokens per seat (~cents total). It is
/// the ground truth that the wire shapes (request bodies, SSE decoding, usage
/// frames) work against the live APIs — the unit tests only cover canned frames.
@main
struct LiveSmoke {
    struct SeatResult {
        var seat: Seat
        var text: String = ""
        var usage: TokenUsage?
        var stopReason: String?
        var deltas = 0
        var error: String?
    }

    static func main() async {
        let seats = [
            Seat(name: "Seat 1 — Anchor", provider: .anthropic, modelID: "claude-opus-4-8", isAnchor: true),
            Seat(name: "Seat 2", provider: .openrouter, modelID: "openai/gpt-5.6-sol-pro"),
            Seat(name: "Seat 3", provider: .openrouter, modelID: "google/gemini-3.1-pro-preview"),
            Seat(name: "Seat 4", provider: .openrouter, modelID: "qwen/qwen3.7-max"),
        ]
        let resolver = KeychainProviderResolver()
        let prompt = "Reply with exactly: quartet-live-ok"
        var results: [SeatResult] = []

        for seat in seats {
            var result = SeatResult(seat: seat)
            print("→ \(seat.name) [\(seat.provider.rawValue) / \(seat.modelID)] …")
            do {
                let apiKey = try resolver.apiKey(for: seat.provider)
                let client = try resolver.client(for: seat)
                let request = SeatRequest(
                    seat: seat,
                    messages: [
                        ChatMessage(role: .system, text: "You are a wire-format smoke test. Follow the instruction exactly."),
                        ChatMessage(role: .user, text: prompt),
                    ],
                    // Reasoning models (gpt-5.6 tier) may burn tokens before emitting
                    // text; give headroom so max_tokens doesn't truncate the reply.
                    maxTokens: 1000)
                for try await chunk in client.stream(request: request, apiKey: apiKey) {
                    switch chunk {
                    case .textDelta(let delta):
                        result.text += delta
                        result.deltas += 1
                    case .usage(let usage):
                        result.usage = usage
                    case .completed(let reason):
                        result.stopReason = reason
                    }
                }
                if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.error = "empty answer (stop=\(result.stopReason ?? "nil"))"
                }
            } catch {
                result.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            results.append(result)
        }

        print("\n================ LIVE SMOKE RESULTS ================")
        let table = PriceTable.bundledDefault
        var failures = 0
        for result in results {
            let usageText: String
            var costText = "price not set"
            if let usage = result.usage {
                usageText = "\(usage.inputTokens) in / \(usage.outputTokens) out"
                if let price = table.price(for: result.seat.modelID) {
                    let usd = Double(usage.inputTokens) / 1_000_000 * price.inputPerMTok
                        + Double(usage.outputTokens) / 1_000_000 * price.outputPerMTok
                    costText = String(format: "$%.5f", usd)
                }
            } else {
                usageText = "NO USAGE REPORTED"
            }
            if let error = result.error {
                failures += 1
                print("FAIL \(result.seat.name) [\(result.seat.modelID)] — \(error)")
            } else {
                print("PASS \(result.seat.name) [\(result.seat.modelID)] — \(usageText), \(costText), stop=\(result.stopReason ?? "nil"), deltas=\(result.deltas)")
                print("     text: \(result.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))")
            }
            if result.usage == nil && result.error == nil {
                // Usage is how the app computes cost — a pass without usage is a wire bug.
                failures += 1
                print("     ^ WIRE BUG: stream completed without a usage frame")
            }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
