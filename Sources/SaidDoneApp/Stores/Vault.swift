import Foundation
import Observation
import SaidDoneCore
import Security

/// API keys, in one Keychain item. Read once at launch; every edit rewrites the item, so there is at most one
/// Keychain prompt per launch for an app whose signature changed, instead of one per vendor.
@MainActor @Observable
final class Vault {
    enum State: Equatable {
        case loading
        case ready
        /// The Keychain refused (denied prompt, locked keychain). Keys typed now are kept until quit.
        case unavailable(OSStatus)
    }

    private(set) var state: State = .loading
    /// The last save failed; settings shows it next to the key fields.
    private(set) var saveFailure: OSStatus?
    private var keys: [VendorID: String] = [:]
    @ObservationIgnored private let item: KeychainItem?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `item` nil keeps keys in memory (tests, previews).
    init(item: KeychainItem?) {
        self.item = item
        if item == nil { state = .ready }
    }

    func load() {
        guard let item, state == .loading else { return }
        Task {
            do {
                keys = try await item.read()
                state = .ready
            } catch let error as KeychainItem.Failure {
                state = .unavailable(error.status)
            } catch {
                state = .unavailable(errSecInternalError)
            }
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// Returns once the initial read has finished.
    func loaded() async {
        guard state == .loading else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func key(_ vendor: VendorID) -> String { keys[vendor, default: ""] }

    func setKey(_ key: String, for vendor: VendorID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keys[vendor, default: ""] != trimmed else { return }
        keys[vendor] = trimmed.isEmpty ? nil : trimmed
        guard let item else { return }
        let snapshot = keys
        Task {
            do {
                try await item.write(snapshot)
                saveFailure = nil
            } catch let error as KeychainItem.Failure {
                saveFailure = error.status
            } catch {
                saveFailure = errSecInternalError
            }
        }
    }

    /// Vendors that have a key.
    var present: Set<VendorID> { Set(keys.keys) }
}

/// One generic-password item holding every key as JSON. The actor serializes Keychain calls; each write stores the
/// whole dictionary, so writes are idempotent and the last one wins.
actor KeychainItem {
    struct Failure: Error { let status: OSStatus }

    private let service: String
    private let account: String

    init(service: String = "SaidDone", account: String = "credentials") {
        self.service = service
        self.account = account
    }

    func read() throws(Failure) -> [VendorID: String] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        let stored = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.map { (VendorID(rawValue: $0.key), $0.value) })
    }

    func write(_ keys: [VendorID: String]) throws(Failure) {
        let data = (try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) })))
            ?? Data()
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
