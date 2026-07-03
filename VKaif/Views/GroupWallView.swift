import SwiftUI

/// Страница группы: инфо (groups.getById) + лента постов (wall.get).
struct GroupWallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var authService: AuthService
    /// ID группы (положительное число, например 12345).
    let groupId: Int
    /// Вызывается после успешной отписки (до dismiss), чтобы родитель обновил список групп.
    var onLeaveSuccess: (() -> Void)? = nil

    @State private var group: VKGroup?
    @State private var posts: [VKPost] = []
    @State private var profiles: [VKProfile] = []
    @State private var groups: [VKGroup] = []
    @State private var groupPhotos: [VKPhoto] = []
    @State private var totalPhotosCount: Int? = nil
    @State private var totalAudioCount: Int? = nil
    @State private var galleryInitialIndex: Int = 0
    @State private var isGalleryPresented = false
    @State private var loadState: GroupWallLoadState = .idle
    @State private var showDescription = false
    @State private var leaveInProgress = false
    @State private var leaveError: String? = nil
    @State private var commentsContext: PostCommentsContext? = nil
    @State private var postLikeOverrides: [String: Int] = [:]
    @State private var postLikedOverrides: [String: Bool] = [:]
    @State private var likeInProgress: Set<String> = []
    @State private var postRepostOverrides: [String: Int] = [:]
    @State private var repostInProgress: Set<String> = []
    @State private var showRepostDMStub = false
    @State private var videoPlayerURL: URL? = nil
    @State private var videoPlayerPost: VKPost? = nil

    private let vkApi = VKApiService()
    private var ownerId: Int { -groupId }

    enum GroupWallLoadState {
        case idle
        case loading
        case loaded
        case failed(Error)
    }

    var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Загрузка…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let g = group {
                            groupHeader(group: g)
                        }
                        ForEach(posts, id: \.postId) { post in
                            groupWallPostRow(post)
                            Divider()
                        }
                    }
                }
            case .failed(let error):
                ContentUnavailableView(
                    "Ошибка",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(error.localizedDescription)
                )
            }
        }
        .navigationTitle(group?.name ?? "Группа")
        .navigationBarTitleDisplayMode(.inline)
        .vkBlueNavBar()
        .toolbar {
            if case .loaded = loadState {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { load() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear { load() }
        .alert("Ошибка отписки", isPresented: Binding(
            get: { leaveError != nil },
            set: { if !$0 { leaveError = nil } }
        )) {
            Button("OK", role: .cancel) { leaveError = nil }
        } message: {
            if let msg = leaveError { Text(msg) }
        }
        .sheet(item: $commentsContext) { ctx in
            PostCommentsView(context: ctx, authService: authService)
        }
        .fullScreenCover(isPresented: Binding(
            get: { videoPlayerURL != nil },
            set: { if !$0 { videoPlayerURL = nil; videoPlayerPost = nil } }
        )) {
            if let url = videoPlayerURL {
                groupWallVideoPlayerContent(url: url)
            }
        }
        .fullScreenCover(isPresented: $isGalleryPresented) {
            let urls = groupPhotos.compactMap { $0.displayURL }.compactMap { URL(string: $0) }
            if !urls.isEmpty {
                FullScreenPhotoGalleryView(
                    urls: urls,
                    initialIndex: min(galleryInitialIndex, urls.count - 1),
                    onDismiss: { isGalleryPresented = false },
                    likesCount: nil,
                    commentsCount: nil,
                    isLiked: false,
                    onLike: nil,
                    photoCommentsContext: nil,
                    authService: authService,
                    photoIdsForSaving: nil,
                    vkApi: vkApi,
                    getAccessToken: { authService.accessToken ?? "" },
                    isOwnPhotos: false,
                    isProfileAlbum: false
                )
            }
        }
        .alert("Репост в личку", isPresented: $showRepostDMStub) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Скоро. Раздел сообщений в разработке.")
        }
    }

    // MARK: - Header

    private func groupHeader(group: VKGroup) -> some View {
        VStack(spacing: 0) {
            // Аватар + имя + тип
            HStack(alignment: .top, spacing: 14) {
                groupAvatarView(group: group)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: VKTheme.Radius.avatarSquare))

                VStack(alignment: .leading, spacing: 5) {
                    Text(group.name ?? "Сообщество")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    let subtitle = group.activity ?? group.status ?? ""
                    if !subtitle.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showDescription.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text(subtitle)
                                    .font(VKTheme.TextStyle.timestamp)
                                    .foregroundStyle(Color.white.opacity(0.6))
                                    .lineLimit(1)
                                if let desc = group.description, !desc.isEmpty {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.6))
                                        .rotationEffect(.degrees(showDescription ? 180 : 0))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Описание (раскрывается)
            if showDescription, let desc = group.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            // Кнопка "Отписаться"
            Button {
                leaveGroup()
            } label: {
                Text(leaveInProgress ? "Отписка…" : "Отписаться")
                    .font(VKTheme.TextStyle.profileAction)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(VKTheme.Radius.button)
            }
            .buttonStyle(.plain)
            .disabled(leaveInProgress)
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Статистика
            groupStatsBlock(group: group)
                .padding(.top, 10)

            // Фотострип
            if !groupPhotos.isEmpty {
                groupPhotoStrip(photos: groupPhotos)
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, 14)
        .background(Color(hex: "#1F2B38"))
    }

    @ViewBuilder
    private func groupAvatarView(group: VKGroup) -> some View {
        let urlString = group.photo200 ?? group.photo100 ?? group.photo50
        if let s = urlString, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure, .empty: groupAvatarPlaceholder
                @unknown default: EmptyView()
                }
            }
        } else {
            groupAvatarPlaceholder
        }
    }

    private var groupAvatarPlaceholder: some View {
        Image(systemName: "person.3.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.white.opacity(0.4))
            .padding(16)
            .background(Color.white.opacity(0.1))
    }

    // MARK: - Статистика группы

    private func groupStatsBlock(group: VKGroup) -> some View {
        HStack(spacing: 0) {
            groupStatCell(value: group.membersCount, label: "участников")
            groupStatDivider
            groupStatCell(value: totalPhotosCount, label: "фото")
            groupStatDivider
            groupStatCell(value: totalAudioCount, label: "аудио")
        }
        .frame(maxWidth: .infinity)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1),
            alignment: .top
        )
    }

    private func groupStatCell(value: Int?, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value.map { formatStatCount($0) } ?? "—")
                .font(VKTheme.TextStyle.statNumber)
                .foregroundStyle(.white)
            Text(label)
                .font(VKTheme.TextStyle.statLabel)
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var groupStatDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1)
            .padding(.vertical, 8)
    }

    private func formatStatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Фотострип

    private func groupPhotoStrip(photos: [VKPhoto]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button {
                        galleryInitialIndex = index
                        isGalleryPresented = true
                    } label: {
                        Group {
                            if let s = photo.displayURL, let url = URL(string: s) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let img): img.resizable().scaledToFill()
                                    default: Color.white.opacity(0.1)
                                    }
                                }
                            } else {
                                Color.white.opacity(0.1)
                            }
                        }
                        .frame(width: 80, height: 80)
                        .clipped()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 80)
    }

    // MARK: - Посты

    @ViewBuilder
    private func groupWallVideoPlayerContent(url: URL) -> some View {
        let post = videoPlayerPost
        let ctx: VideoPlayerPostContext? = post.map { p in
            VideoPlayerPostContext(
                likesCount: postLikeOverrides[p.postId] ?? p.likesCount,
                commentsCount: p.commentsCount,
                isLiked: postLikedOverrides[p.postId] ?? (p.likes?.userLikes == 1),
                onLike: { likeToggle(p) },
                onTapComments: {
                    commentsContext = PostCommentsContext(
                        ownerId: p.ownerId ?? ownerId,
                        postId: p.id,
                        totalCount: p.commentsCount
                    )
                }
            )
        }
        VideoPlayerView(url: url, onDismiss: { videoPlayerURL = nil; videoPlayerPost = nil }, postContext: ctx)
    }

    private func groupWallPostRow(_ post: VKPost) -> some View {
        let repostCount = postRepostOverrides[post.postId]
        let repostLoading = repostInProgress.contains(post.postId)
        let repostToWallAction: (() -> Void)? = repostLoading ? nil : { repostToWall(post) }
        return Group {
            PostCellView(
                post: post,
                authorName: group?.name ?? "Группа",
                authorAvatarURL: group?.photo50,
                relativeDate: relativeDateString(from: post.date),
                calendarDate: calendarDateString(from: post.date),
                profiles: profiles,
                groups: groups,
                authService: nil,
                feedDestination: nil,
                onTapComments: {
                    commentsContext = PostCommentsContext(
                        ownerId: post.ownerId ?? ownerId,
                        postId: post.id,
                        totalCount: post.commentsCount
                    )
                },
                likesCountOverride: postLikeOverrides[post.postId],
                isLikedOverride: postLikedOverrides[post.postId],
                onLike: likeInProgress.contains(post.postId) ? nil : { likeToggle(post) },
                likeInProgress: likeInProgress.contains(post.postId),
                onTapVideo: { video, ownerId, post in
                    var url: URL?
                    if let p = video.player, let u = URL(string: p) {
                        url = u
                    } else {
                        let token = await MainActor.run { authService.accessToken } ?? ""
                        if !token.isEmpty,
                           let res = try? await vkApi.getVideo(token: token, videos: video.videoGetId(ownerFallback: ownerId)),
                           let first = res.items.first,
                           let playerURL = first.player {
                            url = URL(string: playerURL)
                        }
                    }
                    await MainActor.run {
                        videoPlayerURL = url
                        videoPlayerPost = post
                    }
                },
                pollVoteOverrides: nil,
                onPollVote: nil,
                pollVoteInProgress: [],
                repostsCountOverride: repostCount,
                onRepostToWall: repostToWallAction,
                onRepostToDM: { showRepostDMStub = true },
                repostInProgress: repostLoading,
                canDeletePost: false,
                onDelete: nil,
                deleteInProgress: false,
                canPinPost: false,
                isPinned: false,
                onPin: nil,
                onUnpin: nil,
                pinInProgress: false,
                onDeletePhoto: nil,
                onMakeProfilePhoto: nil,
                onRepostSuccessFromGallery: { newCount in postRepostOverrides[post.postId] = newCount },
                vkApi: vkApi,
                getAccessToken: { authService.accessToken ?? "" }
            )
        }
        .padding(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }

    // MARK: - Загрузка

    private func load() {
        guard let token = authService.accessToken else { return }
        loadState = .loading
        Task {
            do {
                async let groupTask = vkApi.getGroupById(token: token, groupId: groupId)
                async let wallTask = vkApi.getWall(token: token, ownerId: ownerId)
                async let photosTask = vkApi.getPhotosAll(token: token, ownerId: ownerId, count: 5)
                async let audioTask = vkApi.getAudio(token: token, ownerId: ownerId, offset: 0, count: 1)
                let g = try? await groupTask
                let wall = try await wallTask
                let photosResp = try? await photosTask
                let audioResp = try? await audioTask
                await MainActor.run {
                    group = g
                    posts = wall.items
                    profiles = wall.profiles ?? []
                    groups = wall.groups ?? []
                    groupPhotos = photosResp?.items ?? []
                    totalPhotosCount = photosResp.map { $0.count > 0 ? $0.count : nil } ?? nil
                    totalAudioCount = audioResp.map { $0.count > 0 ? $0.count : nil } ?? nil
                    loadState = .loaded
                }
            } catch {
                await MainActor.run { loadState = .failed(error) }
            }
        }
    }

    // MARK: - Лайк

    private func likeToggle(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let ownerId = post.ownerId ?? self.ownerId
        let pid = post.postId
        if likeInProgress.contains(pid) { return }
        let isLiked = postLikedOverrides[pid] ?? (post.likes?.userLikes == 1)
        likeInProgress.insert(pid)
        Task {
            do {
                let newCount: Int
                if isLiked {
                    newCount = try await vkApi.likesDelete(token: token, type: "post", ownerId: ownerId, itemId: post.id)
                    await MainActor.run {
                        postLikeOverrides[pid] = newCount
                        postLikedOverrides[pid] = false
                        likeInProgress.remove(pid)
                    }
                } else {
                    newCount = try await vkApi.likesAdd(token: token, type: "post", ownerId: ownerId, itemId: post.id)
                    await MainActor.run {
                        postLikeOverrides[pid] = newCount
                        postLikedOverrides[pid] = true
                        likeInProgress.remove(pid)
                    }
                }
            } catch {
                await MainActor.run { likeInProgress.remove(pid) }
            }
        }
    }

    // MARK: - Репост

    private func repostToWall(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let oid = post.ownerId ?? ownerId
        guard oid != 0 else { return }
        let pid = post.postId
        if repostInProgress.contains(pid) { return }
        repostInProgress.insert(pid)
        let object = "wall\(oid)_\(post.id)"
        Task {
            do {
                let response = try await vkApi.wallRepost(token: token, object: object)
                await MainActor.run {
                    if let newCount = response.repostsCount {
                        postRepostOverrides[pid] = newCount
                    }
                    repostInProgress.remove(pid)
                }
            } catch {
                await MainActor.run { repostInProgress.remove(pid) }
            }
        }
    }

    // MARK: - Отписка

    private func leaveGroup() {
        guard let token = authService.accessToken, !token.isEmpty else {
            leaveError = "Нет доступа. Войдите снова."
            return
        }
        leaveInProgress = true
        Task {
            do {
                try await vkApi.leaveGroup(token: token, groupId: groupId)
                await MainActor.run {
                    leaveInProgress = false
                    onLeaveSuccess?()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    leaveInProgress = false
                    leaveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
