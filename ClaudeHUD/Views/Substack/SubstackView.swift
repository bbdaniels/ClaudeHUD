import SwiftUI

struct SubstackView: View {
    @EnvironmentObject var substackService: SubstackService
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""
    @State private var expandedPostId: Int?
    @State private var showingSaved = false

    private var filteredPosts: [SubstackPost] {
        let posts = showingSaved ? substackService.savedPosts : substackService.activePosts
        if searchText.isEmpty { return posts }
        let query = searchText.lowercased()
        return posts.filter {
            $0.title.lowercased().contains(query)
                || ($0.subtitle?.lowercased().contains(query) ?? false)
                || ($0.publicationName?.lowercased().contains(query) ?? false)
                || ($0.authorName?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar + controls
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary)
                TextField("Search posts...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.smallFont(scale))

                // Feed / Saved toggle
                Button(action: { showingSaved.toggle() }) {
                    HStack(spacing: 3) {
                        Image(systemName: showingSaved ? "bookmark.fill" : "bookmark")
                            .font(.captionFont(scale))
                        if showingSaved {
                            Text("\(substackService.savedPostIDs.count)")
                                .font(.captionFont(scale))
                        }
                    }
                    .foregroundColor(showingSaved ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(showingSaved ? "Show feed" : "Show saved")

                if !showingSaved && substackService.unreadCount > 0 {
                    Text("\(substackService.unreadCount)")
                        .font(.captionFont(scale))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    Button(action: { substackService.markAllRead() }) {
                        Image(systemName: "checkmark.circle")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Mark all read")
                }
                Button(action: {
                    Task { await substackService.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(substackService.isLoading ? 360 : 0))
                        .animation(substackService.isLoading
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default, value: substackService.isLoading)
                }
                .buttonStyle(.borderless)
                .disabled(substackService.isLoading)
                .help("Refresh feed")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.textBackgroundColor).opacity(0.5))

            Divider().opacity(0.3)

            if !substackService.hasCookie {
                noCookieView
            } else if substackService.feedPosts.isEmpty && !substackService.isLoading {
                emptyView
            } else {

                // Feed
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(filteredPosts) { post in
                            Section {
                                if expandedPostId == post.id {
                                    SubstackPostContent(post: post)
                                }
                            } header: {
                                VStack(spacing: 0) {
                                    SubstackPostRow(
                                        post: post,
                                        isRead: substackService.isRead(post.id),
                                        isExpanded: expandedPostId == post.id,
                                        onTap: {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                if expandedPostId == post.id {
                                                    expandedPostId = nil
                                                    proxy.scrollTo(post.id, anchor: .top)
                                                } else {
                                                    expandedPostId = post.id
                                                    substackService.markRead(post.id)
                                                }
                                            }
                                        },
                                        onMarkUnread: { substackService.markUnread(post.id) },
                                        onOpen: { openInBrowser(post) },
                                        onToggleSave: { substackService.toggleSaved(post.id) },
                                        onDismiss: {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                if expandedPostId == post.id {
                                                    expandedPostId = nil
                                                    proxy.scrollTo(post.id, anchor: .top)
                                                }
                                                substackService.dismiss(post.id)
                                            }
                                        },
                                        isSaved: substackService.isSaved(post.id)
                                    )
                                    Divider().opacity(0.2).padding(.leading, 12)
                                }
                                .background(.ultraThinMaterial)
                                .id(post.id)
                            }
                        }
                    }
                }
                }

                // Load more -- outside ScrollView so taps always register
                if !showingSaved && substackService.hasMore && !substackService.feedPosts.isEmpty {
                    Divider().opacity(0.3)
                    Button {
                        Task { await substackService.loadMore() }
                    } label: {
                        HStack {
                            Spacer()
                            if substackService.isLoadingMore {
                                ProgressView().controlSize(.small)
                                Text("Loading...")
                                    .font(.captionFont(scale))
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.captionFont(scale))
                                Text("Load more")
                                    .font(.captionFont(scale))
                            }
                            Spacer()
                        }
                        .foregroundColor(.accentColor)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderless)
                    .disabled(substackService.isLoadingMore)
                }
            }
        }
        .task {
            if substackService.hasCookie && substackService.feedPosts.isEmpty {
                await substackService.refresh()
            }
        }
    }

    private func openInBrowser(_ post: SubstackPost) {
        guard let urlString = post.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private var noCookieView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "newspaper")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Add your substack.sid cookie in the info popover to see your feed here.")
                .font(.smallFont(scale))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            if substackService.isLoading {
                ProgressView()
                Text("Loading feed...")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
            } else if let error = substackService.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                Text(error)
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Retry") {
                    Task { await substackService.refresh() }
                }
                .buttonStyle(.borderless)
                .font(.smallFont(scale))
            } else {
                Text("No posts yet.")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Post Row

struct SubstackPostRow: View {
    let post: SubstackPost
    let isRead: Bool
    let isExpanded: Bool
    let onTap: () -> Void
    let onMarkUnread: () -> Void
    let onOpen: () -> Void
    let onToggleSave: () -> Void
    let onDismiss: () -> Void
    let isSaved: Bool
    @EnvironmentObject var substackService: SubstackService
    @Environment(\.fontScale) private var scale
    @State private var isHovered = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 8) {
                    // Unread dot
                    Circle()
                        .fill(isRead ? Color.clear : Color.accentColor)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 3) {
                        // Publication + date + hover actions
                        HStack(spacing: 4) {
                            Text(post.publicationName ?? post.authorName ?? "Unknown")
                                .font(.captionFont(scale))
                                .foregroundColor(.secondary)
                            Spacer()
                            ZStack(alignment: .trailing) {
                                // Meta text (hidden on hover)
                                HStack(spacing: 4) {
                                    if let wc = post.wordCount, wc > 0 {
                                        Text("\(wc) words")
                                            .font(.captionFont(scale))
                                            .foregroundColor(.secondary.opacity(0.5))
                                        Text("·")
                                            .font(.captionFont(scale))
                                            .foregroundColor(.secondary.opacity(0.3))
                                    }
                                    Text(Self.relativeDateFormatter.localizedString(for: post.postDate, relativeTo: Date()))
                                        .font(.captionFont(scale))
                                        .foregroundColor(.secondary.opacity(0.5))
                                }
                                .opacity(isHovered && !isExpanded ? 0 : 1)

                                // Hover action buttons (shown on hover)
                                HStack(spacing: 0) {
                                    Button(action: { onToggleSave() }) {
                                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                            .font(.captionFont(scale))
                                            .foregroundColor(isSaved ? .accentColor : .secondary.opacity(0.7))
                                            .frame(width: 20 * scale, height: 20 * scale)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .help(isSaved ? "Unsave" : "Save")
                                    Button(action: { onDismiss() }) {
                                        Image(systemName: "xmark")
                                            .font(.captionFont(scale))
                                            .foregroundColor(.secondary.opacity(0.7))
                                            .frame(width: 20 * scale, height: 20 * scale)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Dismiss")
                                }
                                .opacity(isHovered && !isExpanded ? 1 : 0)
                            }
                        }

                        // Title -- bold if unread
                        Text(post.title)
                            .font(isRead ? .smallFont(scale) : .smallMedium(scale))
                            .foregroundColor(.primary)
                            .lineLimit(isExpanded ? nil : 2)

                        // Subtitle preview when collapsed
                        if !isExpanded, let subtitle = post.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.captionFont(scale))
                                .foregroundColor(.secondary.opacity(0.6))
                                .lineLimit(1)
                        }

                        // Badges
                        if !isExpanded && post.audience == "only_paid" {
                            Label("Paid", systemImage: "lock.fill")
                                .font(.captionFont(scale))
                                .foregroundColor(.orange.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered && !isExpanded ? Color.accentColor.opacity(0.05) : Color.clear)
            )
            .onHover { isHovered = $0 }

            // Action bar (pinned with header when scrolling)
            if isExpanded {
                HStack(spacing: 12) {
                    Button(action: onOpen) {
                        Label("Open", systemImage: "safari")
                            .font(.captionFont(scale))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)

                    Button(action: onToggleSave) {
                        Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.captionFont(scale))
                            .foregroundColor(isSaved ? .accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)

                    if isRead {
                        Button(action: onMarkUnread) {
                            Label("Unread", systemImage: "circle")
                                .font(.captionFont(scale))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }

                    if post.audience == "only_paid" {
                        Label("Paid", systemImage: "lock.fill")
                            .font(.captionFont(scale))
                            .foregroundColor(.orange.opacity(0.7))
                    }

                    Spacer()

                    if post.reactionCount > 0 {
                        Label("\(post.reactionCount)", systemImage: "heart")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    if post.commentCount > 0 {
                        Label("\(post.commentCount)", systemImage: "bubble.right")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary.opacity(0.5))
                    }

                    Button(action: onTap) {
                        Image(systemName: "chevron.up")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Collapse")

                    Button(action: onDismiss) {
                        Label("Dismiss", systemImage: "xmark")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Post Content (scrolls under pinned header)

struct SubstackPostContent: View {
    let post: SubstackPost
    @EnvironmentObject var substackService: SubstackService
    @Environment(\.fontScale) private var scale
    @State private var fullBodyHTML: String?
    @State private var isLoadingBody = false
    @State private var webViewHeight: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingBody {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading...")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            } else if let html = fullBodyHTML, !html.isEmpty {
                SubstackWebView(
                    html: html,
                    fontScale: scale,
                    measuredHeight: $webViewHeight
                )
                .frame(height: webViewHeight)
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
        .task {
            guard fullBodyHTML == nil, !isLoadingBody else { return }
            isLoadingBody = true
            fullBodyHTML = await substackService.fetchPostBody(post: post)
            isLoadingBody = false
        }
    }
}
