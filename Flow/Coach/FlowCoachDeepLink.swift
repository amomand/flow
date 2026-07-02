import Foundation

/// Parses `flow://` coach deep links into routes.
///
/// Two forms are accepted:
/// - `flow://coach` opens the coach sheet.
/// - `flow://coach/patch?json=<percent-encoded JSON>` or
///   `flow://coach/patch?d=<base64url JSON>` delivers a routine patch into
///   the pending-patch inbox. An optional `provider` query item records which
///   assistant produced the patch.
///
/// The link is a transport only: the payload lands in the inbox and goes
/// through exactly the same preview and validation as a pasted patch.
enum FlowCoachDeepLink {
    static let scheme = "flow"
    static let coachHost = "coach"

    enum Route: Equatable {
        case openCoach
        case importPatch(json: String, provider: String?)
    }

    enum ParseError: LocalizedError, Equatable {
        /// Not a `flow://coach` URL at all; the caller should ignore it.
        case notCoachURL
        case unknownRoute(String)
        case missingPayload
        case undecodablePayload

        var errorDescription: String? {
            switch self {
            case .notCoachURL:
                return "Not a Flow Coach link."
            case .unknownRoute(let path):
                return "Unrecognised coach link \(path). Use flow://coach or flow://coach/patch."
            case .missingPayload:
                return "Coach patch link is missing its payload. Expected a json or d query item."
            case .undecodablePayload:
                return "Coach patch link payload could not be decoded."
            }
        }
    }

    static func parse(_ url: URL) -> Result<Route, ParseError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == coachHost else {
            return .failure(.notCoachURL)
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch path {
        case "":
            return .success(.openCoach)
        case "patch":
            let items = components.queryItems ?? []
            let provider = value(for: "provider", in: items)
            // URLComponents already percent-decodes query item values.
            if let json = value(for: "json", in: items) {
                return .success(.importPatch(json: json, provider: provider))
            }
            if let encoded = value(for: "d", in: items) {
                guard let json = decodeBase64URL(encoded) else {
                    return .failure(.undecodablePayload)
                }
                return .success(.importPatch(json: json, provider: provider))
            }
            return .failure(.missingPayload)
        default:
            return .failure(.unknownRoute(path))
        }
    }

    private static func value(for name: String, in items: [URLQueryItem]) -> String? {
        guard let value = items.first(where: { $0.name == name })?.value,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Accepts base64url (`-`/`_`, unpadded) and standard base64.
    private static func decodeBase64URL(_ encoded: String) -> String? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
