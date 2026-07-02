import Foundation

/// The shared routine exchange boundary.
///
/// Whole-routine import/export and Flow Coach patch exchange are different
/// products: import duplicates a routine with fresh IDs, while a coach patch
/// edits an existing routine and must validate before anything is saved. They
/// still share one JSON dialect. This namespace owns the conventions both
/// paths use so they cannot drift: encoder/decoder configuration, tolerant
/// extraction of JSON from pasted assistant text, and payload detection.
/// `RoutineStore` remains the only authority for mutating and saving
/// `routines.json`.
enum FlowRoutineExchange {
    /// Canonical encoder for JSON that crosses the app boundary
    /// (coach context, patches, whole-routine export).
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Canonical decoder for JSON that crosses the app boundary.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Extracts the JSON object from pasted text that may be wrapped in
    /// Markdown code fences (```json … ```) or surrounded by assistant prose,
    /// which chat models routinely add. Strips to the outermost `{ … }` span.
    /// Already-clean JSON is returned unchanged (only trimmed).
    ///
    /// Note: this is a deliberately simple outermost-brace extraction. It does
    /// not parse multiple JSON blocks or braces embedded in surrounding prose;
    /// a malformed remainder still fails in `decode` with the original error
    /// path.
    static func sanitizedJSON(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}"),
              firstBrace < lastBrace else {
            return trimmed
        }
        return String(trimmed[firstBrace...lastBrace])
    }

    /// Best-effort identification of a pasted or imported JSON payload, so
    /// each entry point can route mistakes to a helpful message instead of a
    /// generic decode failure. Detection never replaces full decoding and
    /// validation; it only classifies.
    enum PayloadKind: Equatable {
        case routine
        case coachPatch
        case coachContext
        case unknown
    }

    static func detectPayload(in json: String) -> PayloadKind {
        guard let data = sanitizedJSON(from: json).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }
        if object["operations"] != nil, object["routineId"] != nil {
            return .coachPatch
        }
        if object["routines"] != nil, object["schemaVersion"] != nil {
            return .coachContext
        }
        if object["sections"] != nil, object["name"] != nil {
            return .routine
        }
        return .unknown
    }
}

/// Routine revision identity, split so unrelated state changes do not stale
/// coach patches.
///
/// - `contentHash` covers the editable structure a patch operates on: the
///   ordered sections with their exercises (sets, reps, timed duration, rest,
///   notes, per-side, phase overrides). Coach patches pin to this hash.
/// - `stateHash` covers non-structural state, currently `currentPhase`.
///   Toggling the phase changes the state hash but leaves the content hash
///   untouched, so a pending patch stays valid.
///
/// Hash strings carry a scheme prefix (`c1-`, `s1-`) so a hash seen in a
/// patch, an error message, or a future bridge payload is self-describing.
/// Hashes are revision identifiers only, never an auth or integrity
/// mechanism.
enum FlowRoutineRevision {
    static func contentHash(for routine: Routine) -> String {
        guard let data = try? hashingEncoder().encode(routine.sections) else {
            return "c1-unhashable"
        }
        return "c1-" + fnv1a(data)
    }

    static func stateHash(for routine: Routine) -> String {
        "s1-" + fnv1a(Data("currentPhase=\(routine.currentPhase.rawValue)".utf8))
    }

    private static func hashingEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}
