import Foundation

struct SubstackPublication: Identifiable, Codable {
    let id: Int
    let name: String
    let subdomain: String
    let customDomain: String?
    let authorName: String?
    let description: String?
    let logoUrl: String?

    var baseURL: String {
        customDomain ?? "https://\(subdomain).substack.com"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, subdomain
        case customDomain = "custom_domain"
        case authorName = "author_name"
        case description
        case logoUrl = "logo_url"
    }
}

struct SubstackPost: Identifiable, Codable {
    let id: Int
    let title: String
    let subtitle: String?
    let slug: String
    let postDate: Date
    let publicationId: Int
    let url: String?
    let wordCount: Int?
    let audience: String?
    let type: String?
    let authorName: String?
    let bodyText: String?
    var isViewedOnSubstack: Bool = false
    var reactionCount: Int = 0
    var commentCount: Int = 0

    // Populated after fetch
    var publicationName: String?
    var aiSummary: String?

    var webURL: String {
        url ?? ""
    }

    var readingTime: String? {
        guard let wc = wordCount, wc > 0 else { return nil }
        let minutes = max(1, wc / 250)
        return "\(minutes) min"
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, slug
        case postDate = "post_date"
        case publicationId = "publication_id"
        case url = "canonical_url"
        case wordCount = "word_count"
        case audience, type
        case authorName, bodyText
        case isViewedOnSubstack, reactionCount, commentCount
        case publicationName
        case aiSummary
    }

    init(id: Int, title: String, subtitle: String?, slug: String, postDate: Date,
         publicationId: Int, url: String?, wordCount: Int?, audience: String?,
         type: String?, authorName: String?, bodyText: String?,
         isViewedOnSubstack: Bool = false, reactionCount: Int = 0, commentCount: Int = 0,
         publicationName: String? = nil, aiSummary: String? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.slug = slug
        self.postDate = postDate; self.publicationId = publicationId; self.url = url
        self.wordCount = wordCount; self.audience = audience; self.type = type
        self.authorName = authorName; self.bodyText = bodyText
        self.isViewedOnSubstack = isViewedOnSubstack
        self.reactionCount = reactionCount; self.commentCount = commentCount
        self.publicationName = publicationName; self.aiSummary = aiSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        slug = try c.decode(String.self, forKey: .slug)
        postDate = try c.decode(Date.self, forKey: .postDate)
        publicationId = try c.decode(Int.self, forKey: .publicationId)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount)
        audience = try c.decodeIfPresent(String.self, forKey: .audience)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        bodyText = try c.decodeIfPresent(String.self, forKey: .bodyText)
        isViewedOnSubstack = (try? c.decode(Bool.self, forKey: .isViewedOnSubstack)) ?? false
        reactionCount = (try? c.decode(Int.self, forKey: .reactionCount)) ?? 0
        commentCount = (try? c.decode(Int.self, forKey: .commentCount)) ?? 0
        publicationName = try c.decodeIfPresent(String.self, forKey: .publicationName)
        aiSummary = try c.decodeIfPresent(String.self, forKey: .aiSummary)
    }
}

// MARK: - API Response Shapes

struct SubstackSubscriptionsResponse: Codable {
    let subscriptions: [SubstackSubscription]?
    let publications: [SubstackAPIPublication]?
}

struct SubstackSubscription: Codable {
    let id: Int?
    let publicationId: Int?
    let isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case publicationId = "publication_id"
        case isFavorite = "is_favorite"
    }
}

struct SubstackAPIPublication: Codable {
    let id: Int
    let name: String?
    let subdomain: String?
    let customDomain: String?
    let authorName: String?
    let description: String?
    let logoUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, subdomain
        case customDomain = "custom_domain"
        case authorName = "author_name"
        case description
        case logoUrl = "logo_url"
    }

    func toPublication() -> SubstackPublication {
        SubstackPublication(
            id: id,
            name: name ?? "Unknown",
            subdomain: subdomain ?? "",
            customDomain: customDomain,
            authorName: authorName,
            description: description,
            logoUrl: logoUrl
        )
    }
}

struct SubstackFeedResponse: Codable {
    let posts: [SubstackAPIPost]?
}

struct SubstackAPIPost: Codable {
    let id: Int
    let title: String?
    let subtitle: String?
    let slug: String?
    let postDate: String?
    let publicationId: Int?
    let canonicalUrl: String?
    let wordcount: Int?
    let audience: String?
    let type: String?
    let publishedBylines: [SubstackByline]?
    let truncatedBodyText: String?
    let description: String?
    let isViewed: Bool?
    let reactionCount: Int?
    let commentCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, slug, description, audience, type, wordcount
        case postDate = "post_date"
        case publicationId = "publication_id"
        case canonicalUrl = "canonical_url"
        case publishedBylines = "publishedBylines"
        case truncatedBodyText = "truncated_body_text"
        case isViewed = "is_viewed"
        case reactionCount = "reaction_count"
        case commentCount = "comment_count"
    }

    func toPost() -> SubstackPost {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = dateFormatter.date(from: postDate ?? "") ?? Date()

        // Use truncated_body_text (paragraph preview) or description (one-liner)
        let preview = truncatedBodyText ?? description

        return SubstackPost(
            id: id,
            title: title ?? "Untitled",
            subtitle: subtitle,
            slug: slug ?? "",
            postDate: date,
            publicationId: publicationId ?? 0,
            url: canonicalUrl,
            wordCount: wordcount,
            audience: audience,
            type: type,
            authorName: publishedBylines?.first?.name,
            bodyText: preview,
            isViewedOnSubstack: isViewed ?? false,
            reactionCount: reactionCount ?? 0,
            commentCount: commentCount ?? 0,
            publicationName: nil,
            aiSummary: nil
        )
    }
}

struct SubstackByline: Codable {
    let id: Int?
    let name: String?
}
