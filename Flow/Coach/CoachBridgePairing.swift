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
    /// When this endpoint and credential were last proved to work together.
    /// `nil` means the pairing was saved while the device was offline and has
    /// not been checked since, which the UI has to say out loud (#58).
    var verifiedAt: Date?

    /// The device credential. Held separately from the display fields so the
    /// UI layer can pass a pairing around without carrying the secret.
    fileprivate let credential: String

    var endpointDescription: String {
        guard let host = endpoint.host else { return endpoint.absoluteString }
        return host
    }

    var isVerified: Bool { verifiedAt != nil }
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
///
/// Main-actor isolated, like `CoachBridgeSync`: `pair` and `rotateCredential`
/// mutate observable state that SwiftUI reads, and they now do it after an
/// await, so without isolation those writes would resume off the main actor.
/// The network call itself still happens inside the probe's transport.
@MainActor
@Observable
final class CoachBridgePairingStore {
    private(set) var pairing: CoachBridgePairing?
    private(set) var lastError: String?

    private let vault: CoachBridgeVault
    private let probe: CoachBridgePairingProbe

    private struct StoredPairing: Codable {
        let schemaVersion: Int
        let label: String
        let endpoint: URL
        let credential: String
        let pairedAt: Date
        /// Absent in version 1 records, which were written before pairing was
        /// checked at all.
        let verifiedAt: Date?
    }

    /// Version 2 records carry `verifiedAt`. The vault format is otherwise
    /// unchanged, and a version 1 record still decodes.
    private static let schemaVersion = 2

    init(
        vault: CoachBridgeVault = KeychainBridgeVault(),
        probe: CoachBridgePairingProbe = CoachBridgeEdgeProbe()
    ) {
        self.vault = vault
        self.probe = probe
        load()
    }

    var isPaired: Bool { pairing != nil }

    enum PairingError: LocalizedError, Equatable {
        case emptyLabel
        case invalidEndpoint
        case insecureEndpoint
        case emptyCredential
        case vaultUnavailable
        case credentialRejected
        case addressUnreachable
        case notAMailbox
        case mailboxNotReady
        case refused(status: Int)
        case cannotRotateOffline

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
            case .credentialRejected:
                return "The mailbox is there, but it rejected this device credential. Check you pasted the credential for this mailbox, or roll it in the bridge and paste the new one. Nothing was saved."
            case .addressUnreachable:
                return "Nothing answered at that address. Check the address, then try again. Nothing was saved."
            case .notAMailbox:
                return "Something answered at that address, but it is not a coach mailbox. Check the address. Nothing was saved."
            case .mailboxNotReady:
                return "That deployment is not set up as a mailbox yet. The address and the credential are not the problem, and this is not something Flow can fix; the bridge needs configuring first."
            case .refused(let status):
                return "The mailbox refused the check (HTTP \(status)). Nothing was saved."
            case .cannotRotateOffline:
                return "Flow cannot check a new credential while this device is offline, and it will not replace a working one unchecked. Rotate when you have a connection."
            }
        }
    }

    /// Pairs, or re-pairs, this installation. Callers must have confirmed a
    /// switch with the user first: `pendingSwitchWarning(for:)` describes what
    /// changing endpoint means.
    ///
    /// The endpoint and credential are proved against the live mailbox before
    /// anything is written, so a pairing Flow reports as working is one that
    /// has worked at least once (#58). A failed check leaves any previous
    /// pairing exactly as it was: there is no point at which the old record has
    /// been cleared and the new one has not landed.
    @discardableResult
    func pair(label: String, endpointText: String, credential: String, now: Date = Date()) async -> Result<CoachBridgePairing, PairingError> {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { return .failure(.emptyLabel) }
        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCredential.isEmpty else { return .failure(.emptyCredential) }

        let endpoint: URL
        switch Self.normalisedEndpoint(from: endpointText) {
        case .failure(let error):
            return .failure(error)
        case .success(let normalised):
            endpoint = normalised
        }

        let verifiedAt: Date?
        switch await probe.check(endpoint: endpoint, credential: trimmedCredential) {
        case .accepted:
            verifiedAt = now
        case .offline:
            // Pairing on a train should still work. The record is saved
            // unchecked and says so on screen until a real request settles it.
            verifiedAt = nil
        case .credentialRejected:
            return .failure(.credentialRejected)
        case .unreachable:
            return .failure(.addressUnreachable)
        case .notAMailbox:
            return .failure(.notAMailbox)
        case .notReady:
            return .failure(.mailboxNotReady)
        case .refused(let status):
            return .failure(.refused(status: status))
        }

        let record = CoachBridgePairing(
            label: trimmedLabel,
            endpoint: endpoint,
            pairedAt: now,
            verifiedAt: verifiedAt,
            credential: trimmedCredential
        )
        guard persist(record) else { return .failure(.vaultUnavailable) }
        pairing = record
        lastError = nil
        return .success(record)
    }

    /// Replaces the credential without touching the endpoint, for rotation
    /// after the bridge's secret is rolled.
    ///
    /// Checked against the stored endpoint first: a rotation that pastes the
    /// wrong secret must fail here and leave the working credential in place,
    /// rather than presenting as success and breaking the next sync.
    @discardableResult
    func rotateCredential(_ credential: String, now: Date = Date()) async -> Result<CoachBridgePairing, PairingError> {
        guard let current = pairing else { return .failure(.emptyCredential) }
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyCredential) }

        switch await probe.check(endpoint: current.endpoint, credential: trimmed) {
        case .accepted:
            break
        case .offline:
            // Unlike pairing, there is something to lose here: the credential
            // already stored works.
            return .failure(.cannotRotateOffline)
        case .credentialRejected:
            return .failure(.credentialRejected)
        case .unreachable:
            return .failure(.addressUnreachable)
        case .notAMailbox:
            return .failure(.notAMailbox)
        case .notReady:
            return .failure(.mailboxNotReady)
        case .refused(let status):
            return .failure(.refused(status: status))
        }

        let record = CoachBridgePairing(
            label: current.label,
            endpoint: current.endpoint,
            pairedAt: current.pairedAt,
            verifiedAt: now,
            credential: trimmed
        )
        guard persist(record) else { return .failure(.vaultUnavailable) }
        pairing = record
        lastError = nil
        return .success(record)
    }

    /// Records that this endpoint answered a real request, which is the same
    /// proof pairing takes. Ignored when it does not name the current pairing.
    func markVerified(_ endpoint: URL, at date: Date = Date()) {
        guard var current = pairing, current.endpoint == endpoint, !current.isVerified else { return }
        current.verifiedAt = date
        guard persist(current) else { return }
        pairing = current
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
            pairedAt: record.pairedAt,
            verifiedAt: record.verifiedAt
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
            // A version 1 record predates the check and belongs to an
            // installation already syncing with it, so it counts as proven;
            // only a version 2 record can be genuinely unverified.
            verifiedAt: stored.verifiedAt ?? (stored.schemaVersion < 2 ? stored.pairedAt : nil),
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
