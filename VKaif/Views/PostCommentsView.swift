import SwiftUI

struct PostCommentsContext: Identifiable {
    let ownerId: Int
    let postId: Int
    let totalCount: Int
    var id: String { "\(ownerId)_\(postId)" }
}

private enum CommentAuthorDestination: Hashable, Identifiable {
    case user(id: Int)
    case group(id: Int)
    var id: String {
        switch self {
        case .user(let i): return "user-\(i)"
        case .group(let i): return "group-\(i)"
        }
    }
}

struct PostCommentsView: View {
    let context: PostCommentsContext
    @ObservedObject var authService: AuthService

    @State private var items: [VKComment] = []
    @State private var profiles: [VKProfile] = []
    @State private var groups: [VKGroup] = []
    @State private var totalFromApi: Int = 0
    @State private var loadState: CommentsLoadState = .idle
    @State private var loadMoreLoading = false
    @State private var commentLikeOverrides: [Int: Int] = [:]
    @State private var commentLikedOverrides: [Int: Bool] = [:]
    @State private var likeInProgress: Set<Int> = []
    @State private var commentText: String = ""
    @State private var replyTarget: VKComment? = nil
    @State private var isSending = false
    @State private var sendError: String? = nil
    @State private var authorDestination: CommentAuthorDestination? = nil
    @State private var noMoreTopLevel = false
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private let vkApi = VKApiService()
    private let pageSize = 5

    private enum CommentsLoadState {
        case idle, loading, loaded
        case failed(Error)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contentArea
                inputBar
            }
            .navigationTitle("Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .vkBlueNavBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("Назад", systemImage: "chevron.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .navigationDestination(item: $authorDestination) { dest in
                switch dest {
                case .user(let id):
                    ProfileViewWrapper(authService: authService, userId: id)
                case .group(let id):
                    GroupWallView(authService: authService, groupId: id)
                }
            }
        }
        .onAppear(perform: performInitialLoadIfNeeded)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch loadState {
        case .idle, .loading:
            ProgressView("Загрузка комментариев…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            commentsList
        case .failed(let error):
            VStack(spacing: 12) {
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Повторить") { loadFirstPage() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var commentsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items, id: \.id) { comment in
                    commentRow(comment)
                    Divider().padding(.leading, 16 + 36 + 10)
                    if let threadItems = comment.thread?.items, !threadItems.isEmpty {
                        ForEach(threadItems, id: \.id) { reply in
                            commentRow(reply)
                                .padding(.leading, 36)
                            Divider().padding(.leading, 36 + 16 + 36 + 10)
                        }
                    }
                }
                if !items.isEmpty && items.count < totalFromApi && totalFromApi > 5 && !noMoreTopLevel {
                    Button { loadMore() } label: {
                        HStack {
                            if loadMoreLoading { ProgressView().scaleEffect(0.9) }
                            Text(loadMoreLoading ? "Загрузка…" : "Подгрузить ещё")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .foregroundStyle(VKTheme.Colors.primary)
                    .disabled(loadMoreLoading)
                    Divider()
                }
            }
        }
    }

    private func commentRow(_ comment: VKComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if comment.fromId > 0 {
                    authorDestination = .user(id: comment.fromId)
                } else {
                    authorDestination = .group(id: abs(comment.fromId))
                }
            } label: {
                commentAvatar(comment)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if comment.fromId > 0 {
                        authorDestination = .user(id: comment.fromId)
                    } else {
                        authorDestination = .group(id: abs(comment.fromId))
                    }
                } label: {
                    Text(commentAuthorName(comment))
                        .font(VKTheme.TextStyle.postAuthorName)
                        .foregroundColor(VKTheme.Colors.primary)
                }
                .buttonStyle(.plain)

                if !comment.text.isEmpty {
                    Text(stripVKMentions(comment.text))
                        .font(VKTheme.TextStyle.commentBody)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Text(commentTimeString(from: comment.date))
                        .font(VKTheme.TextStyle.commentTimestamp)
                        .foregroundStyle(VKTheme.Colors.textSecondary)
                    Button("Ответить") {
                        replyTarget = comment
                        inputFocused = true
                    }
                    .font(VKTheme.TextStyle.commentTimestamp)
                    .foregroundStyle(VKTheme.Colors.textSecondary)
                    Spacer()
                    likeButton(comment)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func commentAvatar(_ comment: VKComment) -> some View {
        let url: URL? = {
            if comment.fromId > 0 {
                return profiles.first(where: { $0.id == comment.fromId })?.photo50.flatMap { URL(string: $0) }
            } else {
                let gid = abs(comment.fromId)
                return groups.first(where: { $0.id == gid })?.photo50.flatMap { URL(string: $0) }
            }
        }()
        return Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: placeholderAvatar
                    }
                }
            } else {
                placeholderAvatar
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholderAvatar: some View {
        Color(.systemGray5)
            .overlay(
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            )
    }

    private func likeButton(_ comment: VKComment) -> some View {
        let count = commentLikeOverrides[comment.id] ?? comment.likes?.count ?? 0
        let liked = commentLikedOverrides[comment.id] ?? (comment.likes?.userLikes == 1)
        let loading = likeInProgress.contains(comment.id)
        return Button { likeComment(comment) } label: {
            HStack(spacing: 3) {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.caption)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                }
            }
            .foregroundColor(liked ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            if let reply = replyTarget {
                HStack {
                    Text("Ответ для: \(commentAuthorName(reply))")
                        .font(.caption)
                        .foregroundStyle(VKTheme.Colors.textSecondary)
                    Spacer()
                    Button {
                        replyTarget = nil
                        inputFocused = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
            }
            HStack(spacing: 10) {
                Button { } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Комментарий", text: $commentText, axis: .vertical)
                        .font(.system(size: 16))
                        .lineLimit(1...4)
                        .focused($inputFocused)
                    Spacer(minLength: 0)
                    Button { } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                Button {
                    sendComment()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary
                            : VKTheme.Colors.primary)
                }
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Actions

    private func performInitialLoadIfNeeded() {
        if case .idle = loadState { loadFirstPage() }
    }

    private func sendComment() {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let token = authService.accessToken else { return }
        let replyToId = replyTarget?.id
        isSending = true
        sendError = nil
        Task {
            do {
                _ = try await vkApi.wallCreateComment(
                    token: token,
                    ownerId: context.ownerId,
                    postId: context.postId,
                    message: text,
                    replyTo: replyToId
                )
                await MainActor.run {
                    commentText = ""
                    replyTarget = nil
                    inputFocused = false
                    isSending = false
                    loadFirstPage()
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    sendError = error.localizedDescription
                }
            }
        }
    }

    private func likeComment(_ comment: VKComment) {
        guard let token = authService.accessToken else { return }
        let cid = comment.id
        if likeInProgress.contains(cid) { return }
        let liked = commentLikedOverrides[cid] ?? (comment.likes?.userLikes == 1)
        likeInProgress.insert(cid)
        Task {
            do {
                let newCount: Int
                if liked {
                    newCount = try await vkApi.likesDelete(token: token, type: "comment", ownerId: context.ownerId, itemId: cid)
                    await MainActor.run {
                        commentLikeOverrides[cid] = newCount
                        commentLikedOverrides[cid] = false
                        likeInProgress.remove(cid)
                    }
                } else {
                    newCount = try await vkApi.likesAdd(token: token, type: "comment", ownerId: context.ownerId, itemId: cid)
                    await MainActor.run {
                        commentLikeOverrides[cid] = newCount
                        commentLikedOverrides[cid] = true
                        likeInProgress.remove(cid)
                    }
                }
            } catch {
                await MainActor.run { likeInProgress.remove(cid) }
            }
        }
    }

    private func loadFirstPage() {
        noMoreTopLevel = false
        loadState = .loading
        Task { await fetch(offset: 0, append: false) }
    }

    private func loadMore() {
        guard !loadMoreLoading else { return }
        loadMoreLoading = true
        Task {
            await fetch(offset: items.count, append: true)
            loadMoreLoading = false
        }
    }

    private func fetch(offset: Int, append: Bool) async {
        guard let token = authService.accessToken else {
            await MainActor.run { loadState = .failed(VKApiError.missingToken) }
            return
        }
        do {
            let response = try await vkApi.getWallComments(
                token: token,
                ownerId: context.ownerId,
                postId: context.postId,
                offset: offset,
                count: pageSize,
                sort: "asc"
            )
            await MainActor.run {
                if append {
                    if response.items.isEmpty {
                        noMoreTopLevel = true
                    } else {
                        items.append(contentsOf: response.items)
                        mergeProfiles(response.profiles ?? [])
                        mergeGroups(response.groups ?? [])
                    }
                } else {
                    items = response.items
                    profiles = response.profiles ?? []
                    groups = response.groups ?? []
                }
                totalFromApi = response.count
                loadState = .loaded
            }
        } catch {
            await MainActor.run {
                if !append { loadState = .failed(error) }
            }
        }
    }

    private func mergeProfiles(_ new: [VKProfile]) {
        let existingIds = Set(profiles.map(\.id))
        profiles.append(contentsOf: new.filter { !existingIds.contains($0.id) })
    }

    private func mergeGroups(_ new: [VKGroup]) {
        let existingIds = Set(groups.map(\.id))
        groups.append(contentsOf: new.filter { !existingIds.contains($0.id) })
    }

    // MARK: - Helpers

    private func commentAuthorName(_ comment: VKComment) -> String {
        if comment.fromId > 0 {
            if let p = profiles.first(where: { $0.id == comment.fromId }) {
                return [p.firstName, p.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
        } else {
            let gid = abs(comment.fromId)
            if let g = groups.first(where: { $0.id == gid }) {
                return g.name ?? "Группа"
            }
        }
        return "ID\(comment.fromId)"
    }

    private func commentTimeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        guard interval > 0 else { return "только что" }
        if interval < 60 { return "только что" }
        if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) \(minutesWord(minutes)) назад"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'вчера в' HH:mm"
        } else {
            formatter.dateFormat = "d MMM 'в' HH:mm"
        }
        return formatter.string(from: date)
    }

    private func minutesWord(_ n: Int) -> String {
        let n10 = n % 10, n100 = n % 100
        if n100 >= 11 && n100 <= 19 { return "минут" }
        if n10 == 1 { return "минуту" }
        if n10 >= 2 && n10 <= 4 { return "минуты" }
        return "минут"
    }

    /// Заменяет VK-разметку упоминаний [id123|Имя] и [club123|Название] на отображаемое имя.
    private func stripVKMentions(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\[(?:id|club|public)\\d+\\|([^\\]]+)\\]") else { return text }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }
}
