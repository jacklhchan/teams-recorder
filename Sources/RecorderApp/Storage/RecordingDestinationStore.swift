import Foundation

struct RecordingDestinationIdentity: Codable, Equatable, Hashable, Sendable {
    let id: UUID
}

enum RecordingDestinationBookmarkKind: String, Codable, Equatable, Sendable {
    case securityScoped
    case standard
}

enum RecordingDestinationState: String, Codable, Equatable, Sendable {
    case ready
    case needsFolderAccess
    case unavailable
}

struct RecordingDestinationSelection: Equatable, Sendable {
    let identity: RecordingDestinationIdentity?
    let url: URL
    let state: RecordingDestinationState
}

final class RecordingDestinationAccess: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var closeOperation: (() -> Void)?

    init(url: URL, close: @escaping () -> Void) {
        self.url = url
        closeOperation = close
    }

    func close() {
        lock.lock()
        let operation = closeOperation
        closeOperation = nil
        lock.unlock()
        operation?()
    }

    deinit { close() }
}

struct RecordingDestinationBookmarkCodec: @unchecked Sendable {
    let prefersSecurityScope: Bool
    let encodeScoped: (URL) throws -> Data
    let encodeStandard: (URL) throws -> Data
    let resolve: (Data, RecordingDestinationBookmarkKind) throws -> (url: URL, stale: Bool)
    let startAccessing: (URL) -> Bool
    let stopAccessing: (URL) -> Void

    static let live = RecordingDestinationBookmarkCodec(
        prefersSecurityScope: ProcessInfo.processInfo.environment[
            "APP_SANDBOX_CONTAINER_ID"
        ] != nil,
        encodeScoped: { try $0.bookmarkData(options: [.withSecurityScope]) },
        encodeStandard: { try $0.bookmarkData(options: []) },
        resolve: { data, kind in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: kind == .securityScoped ? [.withSecurityScope] : [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url, stale)
        },
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

protocol RecordingDestinationStoring: AnyObject {
    var currentIdentity: RecordingDestinationIdentity? { get }
    func restore(defaultURL: URL) -> RecordingDestinationSelection
    func save(_ url: URL) throws
    func access(identity: RecordingDestinationIdentity) throws -> RecordingDestinationAccess
    func prune(keeping identities: Set<RecordingDestinationIdentity>)
}

final class RecordingDestinationStore: RecordingDestinationStoring {
    static let bookmarkKey = "recordingDestinationBookmarkCatalogV1"
    private static let currentIdentityKey = "recordingDestinationCurrentIdentityV1"

    private struct Catalog: Codable {
        let version: Int
        var entries: [Entry]
    }

    private struct Entry: Codable {
        let identity: RecordingDestinationIdentity
        let path: String
        let bookmarkKind: RecordingDestinationBookmarkKind
        let bookmarkData: Data
    }

    private enum StoreError: Error {
        case destinationNotFound
        case bookmarkResolutionFailed
        case folderAccessUnavailable
    }

    private enum CurrentIdentityLoadResult {
        case absent
        case valid(RecordingDestinationIdentity)
        case corrupt
    }

    private let defaults: UserDefaults
    private let codec: RecordingDestinationBookmarkCodec

    init(defaults: UserDefaults = .standard, codec: RecordingDestinationBookmarkCodec = .live) {
        self.defaults = defaults
        self.codec = codec
    }

    var currentIdentity: RecordingDestinationIdentity? {
        guard case let .valid(identity) = loadCurrentIdentity() else { return nil }
        return identity
    }

    var savedBookmarkKind: RecordingDestinationBookmarkKind? {
        guard let currentIdentity,
              let catalog = loadCatalog() else { return nil }
        return catalog.entries.first(where: { $0.identity == currentIdentity })?.bookmarkKind
    }

    func restore(defaultURL: URL) -> RecordingDestinationSelection {
        switch loadCurrentIdentity() {
        case .absent:
            return RecordingDestinationSelection(identity: nil, url: defaultURL, state: .ready)
        case .corrupt:
            guard let catalog = loadCatalog(), catalog.entries.count == 1,
                  let entry = catalog.entries.first else {
                return RecordingDestinationSelection(identity: nil, url: defaultURL, state: .unavailable)
            }
            return RecordingDestinationSelection(
                identity: entry.identity,
                url: URL(fileURLWithPath: entry.path, isDirectory: true),
                state: .needsFolderAccess
            )
        case let .valid(identity):
            return restore(identity: identity, defaultURL: defaultURL)
        }
    }

    private func restore(
        identity: RecordingDestinationIdentity,
        defaultURL: URL
    ) -> RecordingDestinationSelection {
        guard let entry = loadCatalog()?.entries.first(where: { $0.identity == identity }) else {
            return RecordingDestinationSelection(identity: identity, url: defaultURL, state: .unavailable)
        }

        let intendedURL = URL(fileURLWithPath: entry.path, isDirectory: true)
        do {
            let resolved = try codec.resolve(entry.bookmarkData, entry.bookmarkKind)
            guard !resolved.stale, normalizedPath(resolved.url) == entry.path else {
                return RecordingDestinationSelection(identity: identity, url: intendedURL, state: .needsFolderAccess)
            }
            return RecordingDestinationSelection(identity: identity, url: intendedURL, state: .ready)
        } catch {
            return RecordingDestinationSelection(identity: identity, url: intendedURL, state: .needsFolderAccess)
        }
    }

    func save(_ url: URL) throws {
        let path = normalizedPath(url)
        let bookmarkKind: RecordingDestinationBookmarkKind
        let bookmarkData: Data
        if codec.prefersSecurityScope {
            do {
                bookmarkData = try codec.encodeScoped(url)
                bookmarkKind = .securityScoped
            } catch {
                bookmarkData = try codec.encodeStandard(url)
                bookmarkKind = .standard
            }
        } else {
            bookmarkData = try codec.encodeStandard(url)
            bookmarkKind = .standard
        }

        let identity = RecordingDestinationIdentity(id: UUID())
        var catalog = loadCatalog() ?? Catalog(version: 1, entries: [])
        catalog.entries.append(Entry(
            identity: identity,
            path: path,
            bookmarkKind: bookmarkKind,
            bookmarkData: bookmarkData
        ))
        try persist(catalog: catalog, currentIdentity: identity)
    }

    func access(identity: RecordingDestinationIdentity) throws -> RecordingDestinationAccess {
        guard let entry = loadCatalog()?.entries.first(where: { $0.identity == identity }) else {
            throw StoreError.destinationNotFound
        }
        let resolved = try codec.resolve(entry.bookmarkData, entry.bookmarkKind)
        guard !resolved.stale, normalizedPath(resolved.url) == entry.path else {
            throw StoreError.bookmarkResolutionFailed
        }

        guard entry.bookmarkKind == .securityScoped else {
            return RecordingDestinationAccess(url: resolved.url, close: {})
        }
        guard codec.startAccessing(resolved.url) else {
            throw StoreError.folderAccessUnavailable
        }
        return RecordingDestinationAccess(url: resolved.url) { [codec] in
            codec.stopAccessing(resolved.url)
        }
    }

    func prune(keeping identities: Set<RecordingDestinationIdentity>) {
        guard var catalog = loadCatalog() else { return }
        var retained = identities
        if let currentIdentity {
            retained.insert(currentIdentity)
        }
        catalog.entries.removeAll { !retained.contains($0.identity) }
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: Self.bookmarkKey)
    }

    private func loadCatalog() -> Catalog? {
        guard let data = defaults.data(forKey: Self.bookmarkKey),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.version == 1 else { return nil }
        return catalog
    }

    private func loadCurrentIdentity() -> CurrentIdentityLoadResult {
        guard let data = defaults.data(forKey: Self.currentIdentityKey) else { return .absent }
        guard let identity = try? JSONDecoder().decode(RecordingDestinationIdentity.self, from: data) else {
            return .corrupt
        }
        return .valid(identity)
    }

    private func persist(catalog: Catalog, currentIdentity: RecordingDestinationIdentity) throws {
        let encoder = JSONEncoder()
        defaults.set(try encoder.encode(catalog), forKey: Self.bookmarkKey)
        defaults.set(try encoder.encode(currentIdentity), forKey: Self.currentIdentityKey)
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
