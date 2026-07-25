import Foundation
import Security

/// The remote mailbox this Flow installation is paired with (#39).
///
/// One installation pairs with exactly one mailbox in v1. `label` is display
/// text so the person can tell their own mailbox from someone else's; it is
/// never an authorization input. Authorization is the endpoint plus the device
/// credential, and the bridge resolves the mailbox from its own deployment
/// configuration, so a wrong label cannot reach another person's data.
struct CoachBridgePairing: Equatable {
    let label: String
    let endpoint: URL
    let pairedAt: Date

    /// The device credential. Held separately from the display fields so the
    /// UI layer can pass a pairing around without carrying the secret.
    fileprivate let credential: String

    var endpointDescription: String {
        guard let host = endpoint.host else { return endpoint.absoluteString }
        return host
    }
}

/// Where a pairing is kept. The Keychain implementation is the real one; tests
/// inject an in-memory vault so they never depend on a simulator keychain.
protocol CoachBridgeVault {
    func read() -> Data?
    @discardableResult func write(_ data: Data) -> Bool
    @discardableResult func clear() -> Bool
}

/// Keychain-backed vault, device-only and not synced to iCloud: a device
/// credential must never travel to another device, because each installation
/// pairs separately and rotation has to be per device.
struct KeychainBridgeVault: CoachBridgeVault {
    private let service: String
    private let account: String

    init(service: String = "uk.co.flow.coach.bridge", account: String = "active-mailbox") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// In-memory vault for tests and previews.
final class InMemoryBridgeVault: CoachBridgeVault {
    private var stored: Data?

    init(stored: Data? = nil) {
        self.stored = stored
    }

    func read() -> Data? { stored }

    @discardableResult
    func write(_ data: Data) -> Bool {
        stored = data
        return true
    }

    @discardableResult
    func clear() -> Bool {
        stored = nil
        return true
    }
}

/// Owns the single active pairing and the rules around changing it.
///
/// Pairing is deliberately explicit and destructive-by-confirmation: switching
/// mailboxes is how coach data would cross between people, so the store
/// reports what a switch will discard rather than silently re-pointing sync at
/// a new endpoint.
@Observable
final class CoachBridgePairingStore {
    private(set) var pairing: CoachBridgePairing?
    private(set) var lastError: String?

    private let vault: CoachBridgeVault

    private struct StoredPairing: Codable {
        let schemaVersion: Int
        let label: String
        let endpoint: URL
        let credential: String
        let pairedAt: Date
    }

    private static let schemaVersion = 1

    init(vault: CoachBridgeVault = KeychainBridgeVault()) {
        self.vault = vault
        load()
    }

    var isPaired: Bool { pairing != nil }

    enum PairingError: LocalizedError, Equatable {
        case emptyLabel
        case invalidEndpoint
        case insecureEndpoint
        case emptyCredential
        case vaultUnavailable

        var errorDescription: String? {
            switch self {
            case .emptyLabel:
                return "Give this mailbox a name so you can tell it apart from anyone else's."
            case .invalidEndpoint:
                return "That does not look like a mailbox address."
            case .insecureEndpoint:
                return "The mailbox address must be https."
            case .emptyCredential:
                return "Paste the device credential for this mailbox."
            case .vaultUnavailable:
                return "Could not save the pairing to the Keychain."
            }
        }
    }

    /// Pairs, or re-pairs, this installation. Callers must have confirmed a
    /// switch with the user first: `pendingSwitchWarning(for:)` describes what
    /// changing endpoint means.
    @discardableResult
    func pair(label: String, endpointText: String, credential: String, now: Date = Date()) -> Result<CoachBridgePairing, PairingError> {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { return .failure(.emptyLabel) }
        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCredential.isEmpty else { return .failure(.emptyCredential) }

        switch Self.normalisedEndpoint(from: endpointText) {
        case .failure(let error):
            return .failure(error)
        case .success(let endpoint):
            let record = CoachBridgePairing(
                label: trimmedLabel,
                endpoint: endpoint,
                pairedAt: now,
                credential: trimmedCredential
            )
            guard persist(record) else { return .failure(.vaultUnavailable) }
            pairing = record
            lastError = nil
            return .success(record)
        }
    }

    /// Replaces the credential without touching the endpoint, for rotation
    /// after the bridge's secret is rolled.
    @discardableResult
    func rotateCredential(_ credential: String) -> Result<CoachBridgePairing, PairingError> {
        guard let current = pairing else { return .failure(.emptyCredential) }
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyCredential) }
        let record = CoachBridgePairing(
            label: current.label,
            endpoint: current.endpoint,
            pairedAt: current.pairedAt,
            credential: trimmed
        )
        guard persist(record) else { return .failure(.vaultUnavailable) }
        pairing = record
        lastError = nil
        return .success(record)
    }

    /// Signs out of the mailbox. Local routines, inbox records, and edit
    /// history are untouched: this only stops remote calls.
    @discardableResult
    func unpair() -> Bool {
        guard vault.clear() else {
            lastError = "Could not remove the pairing from the Keychain."
            return false
        }
        pairing = nil
        lastError = nil
        return true
    }

    /// The credential, read only when a request is about to be signed.
    func credential() -> String? {
        pairing?.credential
    }

    /// True when the supplied endpoint would move this installation to a
    /// different mailbox, which is the case the UI must warn about.
    func isSwitch(to endpointText: String) -> Bool {
        guard let current = pairing,
              case .success(let candidate) = Self.normalisedEndpoint(from: endpointText) else { return false }
        return candidate != current.endpoint
    }

    private func persist(_ record: CoachBridgePairing) -> Bool {
        let stored = StoredPairing(
            schemaVersion: Self.schemaVersion,
            label: record.label,
            endpoint: record.endpoint,
            credential: record.credential,
            pairedAt: record.pairedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stored) else { return false }
        return vault.write(data)
    }

    private func load() {
        guard let data = vault.read() else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(StoredPairing.self, from: data) else {
            // A credential we cannot read is a credential we cannot use. Say so
            // rather than silently presenting as unpaired, so the person knows
            // to pair again instead of wondering why sync is quiet.
            lastError = "The saved mailbox pairing could not be read. Pair this installation again."
            return
        }
        pairing = CoachBridgePairing(
            label: stored.label,
            endpoint: stored.endpoint,
            pairedAt: stored.pairedAt,
            credential: stored.credential
        )
    }

    static func normalisedEndpoint(from text: String) -> Result<URL, PairingError> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.invalidEndpoint) }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host != nil else {
            return .failure(.invalidEndpoint)
        }
        let isLoopback = url.host == "127.0.0.1" || url.host == "localhost"
        // Plain HTTP is allowed only against a loopback address, which is how
        // the bridge is exercised locally with wrangler dev. Anything else on
        // the network carries a bearer credential and must be TLS.
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            return .failure(.insecureEndpoint)
        }
        return .success(url)
    }
}
