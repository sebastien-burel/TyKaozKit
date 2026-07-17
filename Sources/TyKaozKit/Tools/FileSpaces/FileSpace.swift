import Foundation

/// A folder the user has explicitly authorised the app to read. Persistence
/// stores a security-scoped bookmark (the sandbox requires this to regain
/// access across launches); the display name is the folder's last path
/// component, kept so the UI and tools can show something readable.
public struct FileSpace: Identifiable, Hashable, Codable {
    public let id: UUID
    public let name: String
    public var bookmark: Data

    public init(id: UUID = UUID(), name: String, bookmark: Data) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
    }
}

/// A resolved, security-scoped root ready to hand to the file tools. The URL
/// carries the sandbox capability; callers must bracket actual file access
/// with `start`/`stopAccessingSecurityScopedResource`.
public struct AuthorizedRoot: Hashable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}
