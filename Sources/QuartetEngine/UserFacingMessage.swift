import Foundation

/// Single home for the "best human-readable message for this error" idiom.
/// Prefers LocalizedError's description, falls back to the debug description.
public func userFacingMessage(for error: Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription {
        return localized
    }
    return String(describing: error)
}
