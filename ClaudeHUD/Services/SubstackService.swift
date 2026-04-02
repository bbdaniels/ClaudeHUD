import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "SubstackService")

@MainActor
class SubstackService: ObservableObject {
    @Published var publications: [SubstackPublication] = []
    @Published var feedPosts: [SubstackPost] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = true
    private var currentOffset = 0
    @Published var errorMessage: String?
    @Published var hasCookie: Bool = false
    @Published var readPostIDs: Set<Int> = []
    @Published var savedPostIDs: Set<Int> = []

    private static let cacheDir: String = {
        let dir = "\(NSHomeDirectory())/.claude/hud/substack"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let keychainService = "com.claudehud.substack"
    private static let keychainAccount = "substack.sid"

    var unreadCount: Int {
        activePosts.filter { !readPostIDs.contains($0.id) }.count
    }

    init() {
        hasCookie = Self.loadCookie() != nil
        readPostIDs = Self.loadReadState()
        savedPostIDs = Self.loadSavedState()
        dismissedPostIDs = Self.loadDismissedState()
        if let cached = Self.loadCachedFeed() {
            feedPosts = cached
            // Align to page boundary so pagination works
            currentOffset = (cached.count / 20) * 20
        }
        if let cached = Self.loadCachedPublications() {
            publications = cached
        }
    }

    // MARK: - Read State

    func isRead(_ postId: Int) -> Bool {
        readPostIDs.contains(postId)
    }

    func markRead(_ postId: Int) {
        readPostIDs.insert(postId)
        Self.saveReadState(readPostIDs)
    }

    func markUnread(_ postId: Int) {
        readPostIDs.remove(postId)
        Self.saveReadState(readPostIDs)
    }

    func markAllRead() {
        for post in feedPosts {
            readPostIDs.insert(post.id)
        }
        Self.saveReadState(readPostIDs)
    }

    // MARK: - Dismiss (Archive)

    @Published var dismissedPostIDs: Set<Int> = []

    func dismiss(_ postId: Int) {
        dismissedPostIDs.insert(postId)
        markRead(postId)
        Self.saveDismissedState(dismissedPostIDs)
    }

    func undismiss(_ postId: Int) {
        dismissedPostIDs.remove(postId)
        Self.saveDismissedState(dismissedPostIDs)
    }

    var activePosts: [SubstackPost] {
        feedPosts.filter { !dismissedPostIDs.contains($0.id) }
    }

    nonisolated private static func dismissedStatePath() -> String {
        "\(cacheDir)/dismissed.json"
    }

    nonisolated private static func loadDismissedState() -> Set<Int> {
        guard let data = FileManager.default.contents(atPath: dismissedStatePath()) else { return [] }
        return (try? JSONDecoder().decode(Set<Int>.self, from: data)) ?? []
    }

    nonisolated private static func saveDismissedState(_ ids: Set<Int>) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        FileManager.default.createFile(atPath: dismissedStatePath(), contents: data)
    }

    // MARK: - Save State

    func isSaved(_ postId: Int) -> Bool {
        savedPostIDs.contains(postId)
    }

    func toggleSaved(_ postId: Int) {
        if savedPostIDs.contains(postId) {
            savedPostIDs.remove(postId)
        } else {
            savedPostIDs.insert(postId)
        }
        Self.saveSavedState(savedPostIDs)
    }

    var savedPosts: [SubstackPost] {
        feedPosts.filter { savedPostIDs.contains($0.id) }
    }

    nonisolated private static func savedStatePath() -> String {
        "\(cacheDir)/saved.json"
    }

    nonisolated private static func loadSavedState() -> Set<Int> {
        guard let data = FileManager.default.contents(atPath: savedStatePath()) else { return [] }
        return (try? JSONDecoder().decode(Set<Int>.self, from: data)) ?? []
    }

    nonisolated private static func saveSavedState(_ ids: Set<Int>) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        FileManager.default.createFile(atPath: savedStatePath(), contents: data)
    }

    nonisolated private static func readStatePath() -> String {
        "\(cacheDir)/read.json"
    }

    nonisolated private static func loadReadState() -> Set<Int> {
        guard let data = FileManager.default.contents(atPath: readStatePath()) else { return [] }
        return (try? JSONDecoder().decode(Set<Int>.self, from: data)) ?? []
    }

    nonisolated private static func saveReadState(_ ids: Set<Int>) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        FileManager.default.createFile(atPath: readStatePath(), contents: data)
    }

    // MARK: - Cookie Management

    static func saveCookie(_ cookie: String) {
        let data = cookie.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
        try? deleteKeychainItem()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
        logger.info("Substack cookie saved to Keychain")
    }

    static func loadCookie() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteCookie() {
        try? deleteKeychainItem()
        logger.info("Substack cookie deleted from Keychain")
    }

    private static func deleteKeychainItem() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Fetch Feed

    func fetchFeed() async {
        guard let cookie = Self.loadCookie() else {
            errorMessage = "No Substack cookie configured. Add it in the info popover."
            return
        }

        isLoading = true
        errorMessage = nil
        currentOffset = 0
        hasMore = true

        do {
            let posts = try await Self.fetchReaderPage(cookie: cookie, offset: 0)
            currentOffset = posts.count
            hasMore = posts.count >= 20

            var resolved = resolvePubNames(posts)
            feedPosts = resolved.sorted { $0.postDate > $1.postDate }
            // Seed read state from Substack's is_viewed
            for post in feedPosts where post.isViewedOnSubstack {
                readPostIDs.insert(post.id)
            }
            Self.saveReadState(readPostIDs)
            Self.saveCachedFeed(feedPosts)
            logger.info("Fetched \(posts.count) feed posts")
        } catch {
            logger.error("Failed to fetch feed: \(error.localizedDescription)")
            errorMessage = "Failed to fetch feed: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func loadMore() async {
        guard let cookie = Self.loadCookie(), !isLoadingMore, hasMore else { return }

        isLoadingMore = true

        // The reader/posts endpoint doesn't paginate, so fetch per-publication
        // Use the earliest post date we have as the cutoff
        let earliestDate = feedPosts.map(\.postDate).min() ?? Date()
        let existingIDs = Set(feedPosts.map(\.id))

        var newPosts: [SubstackPost] = []

        // Fetch from up to 20 publications concurrently
        let pubs = Array(publications.prefix(50))
        await withTaskGroup(of: [SubstackPost].self) { group in
            for pub in pubs {
                group.addTask {
                    (try? await Self.fetchPublicationPosts(
                        subdomain: pub.subdomain, cookie: cookie, limit: 5
                    )) ?? []
                }
            }
            for await posts in group {
                let older = posts.filter { !existingIDs.contains($0.id) && $0.postDate < earliestDate }
                newPosts.append(contentsOf: older)
            }
        }

        if newPosts.isEmpty {
            hasMore = false
        } else {
            let resolved = resolvePubNames(newPosts)
            feedPosts.append(contentsOf: resolved)
            feedPosts.sort { $0.postDate > $1.postDate }
            Self.saveCachedFeed(feedPosts)
        }

        isLoadingMore = false
    }

    private func resolvePubNames(_ posts: [SubstackPost]) -> [SubstackPost] {
        let pubMap = Dictionary(uniqueKeysWithValues: publications.map { ($0.id, $0.name) })
        var resolved = posts
        for i in resolved.indices {
            resolved[i].publicationName = pubMap[resolved[i].publicationId]
                ?? resolved[i].authorName
        }
        return resolved
    }

    func fetchSubscriptions() async {
        guard let cookie = Self.loadCookie() else { return }

        do {
            let pubs = try await Self.fetchSubscriptionList(cookie: cookie)
            publications = pubs
            Self.saveCachedPublications(pubs)
            logger.info("Fetched \(pubs.count) subscriptions")
        } catch {
            logger.error("Failed to fetch subscriptions: \(error.localizedDescription)")
        }
    }

    func refresh() async {
        await fetchSubscriptions()
        await fetchFeed()
    }

    // MARK: - Post Body

    /// Fetch full post body on demand (by slug + base URL)
    func fetchPostBody(post: SubstackPost) async -> String? {
        guard let cookie = Self.loadCookie() else { return nil }

        // Check body cache
        if let cached = Self.loadCachedBody(postId: post.id) {
            return cached
        }

        // Resolve the API base URL
        let baseURL: String
        let isTrustedHost: Bool
        if let pub = publications.first(where: { $0.id == post.publicationId }) {
            baseURL = "https://\(pub.subdomain).substack.com"
            isTrustedHost = true
        } else if let url = post.url, let parsed = URL(string: url),
                  let host = parsed.host {
            // Enforce HTTPS; only send cookie to *.substack.com or known publication custom domains
            baseURL = "https://\(host)"
            let knownCustomDomains = Set(publications.compactMap { $0.customDomain }.compactMap { URL(string: $0)?.host })
            isTrustedHost = host.hasSuffix(".substack.com") || knownCustomDomains.contains(host)
        } else {
            return nil
        }

        do {
            let body = try await Self.fetchPostHTML(baseURL: baseURL, slug: post.slug, cookie: isTrustedHost ? cookie : nil)
            if let body = body {
                Self.saveCachedBody(postId: post.id, body: body)
            }
            return body
        } catch {
            logger.error("Failed to fetch post body: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func fetchPostHTML(baseURL: String, slug: String, cookie: String?) async throws -> String? {
        let urlString = "\(baseURL)/api/v1/posts/\(slug)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        if let cookie = cookie {
            request.setValue("substack.sid=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }

        struct PostResponse: Codable { let body_html: String? }
        let decoded = try JSONDecoder().decode(PostResponse.self, from: data)
        return decoded.body_html
    }

    // Body cache (permanent, keyed by post ID)
    nonisolated private static func bodyCachePath(postId: Int) -> String {
        "\(cacheDir)/body_\(postId).html"
    }

    nonisolated private static func loadCachedBody(postId: Int) -> String? {
        try? String(contentsOfFile: bodyCachePath(postId: postId), encoding: .utf8)
    }

    nonisolated private static func saveCachedBody(postId: Int, body: String) {
        try? body.write(toFile: bodyCachePath(postId: postId), atomically: true, encoding: .utf8)
    }

    // MARK: - API Calls

    nonisolated private static func fetchReaderPage(cookie: String, offset: Int) async throws -> [SubstackPost] {
        guard let url = URL(string: "https://substack.com/api/v1/reader/posts?limit=20&offset=\(offset)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("substack.sid=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw SubstackError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let feedResponse = try decoder.decode(SubstackFeedResponse.self, from: data)
        return feedResponse.posts?.map { $0.toPost() } ?? []
    }

    nonisolated private static func fetchPublicationPosts(subdomain: String, cookie: String, limit: Int) async throws -> [SubstackPost] {
        guard !subdomain.isEmpty,
              let url = URL(string: "https://\(subdomain).substack.com/api/v1/posts?limit=\(limit)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("substack.sid=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return [] }

        let decoded = try JSONDecoder().decode([SubstackAPIPost].self, from: data)
        return decoded.map { $0.toPost() }
    }

    nonisolated private static func fetchSubscriptionList(cookie: String) async throws -> [SubstackPublication] {
        var request = URLRequest(url: URL(string: "https://substack.com/api/v1/subscriptions")!)
        request.setValue("substack.sid=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw SubstackError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let subsResponse = try decoder.decode(SubstackSubscriptionsResponse.self, from: data)
        return subsResponse.publications?.map { $0.toPublication() } ?? []
    }

    // MARK: - Disk Cache

    nonisolated private static func feedCachePath() -> String {
        "\(cacheDir)/feed.json"
    }

    nonisolated private static func pubsCachePath() -> String {
        "\(cacheDir)/publications.json"
    }

    nonisolated private static func loadCachedFeed() -> [SubstackPost]? {
        let path = feedCachePath()
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // Only use cache if less than 1 hour old
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 3600 {
            return nil
        }
        return try? JSONDecoder().decode([SubstackPost].self, from: data)
    }

    nonisolated private static func saveCachedFeed(_ posts: [SubstackPost]) {
        guard let data = try? JSONEncoder().encode(posts) else { return }
        FileManager.default.createFile(atPath: feedCachePath(), contents: data)
    }

    nonisolated private static func loadCachedPublications() -> [SubstackPublication]? {
        let path = pubsCachePath()
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // Publications cache: 24h TTL
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 86400 {
            return nil
        }
        return try? JSONDecoder().decode([SubstackPublication].self, from: data)
    }

    nonisolated private static func saveCachedPublications(_ pubs: [SubstackPublication]) {
        guard let data = try? JSONEncoder().encode(pubs) else { return }
        FileManager.default.createFile(atPath: pubsCachePath(), contents: data)
    }
}

// MARK: - Errors

enum SubstackError: LocalizedError {
    case httpError(Int)
    case noCookie

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP \(code)"
        case .noCookie: return "No Substack cookie configured"
        }
    }
}
