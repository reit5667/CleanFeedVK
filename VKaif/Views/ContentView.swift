import SwiftUI

/// Навигация из ленты: тап по автору поста → группа или профиль пользователя.
enum FeedDestination: Hashable {
    case group(id: Int)
    case user(id: Int)
}

struct ContentView: View {

    @StateObject private var authService: AuthService
    /// Один ViewModel для таба «Профиль» — не пересоздаётся при переключении табов, данные друзей/групп/альбомов сохраняются.
    @StateObject private var profileViewModel: ProfileViewModel
    @State private var showAuthView = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        let auth = AuthService()
        _authService = StateObject(wrappedValue: auth)
        _profileViewModel = StateObject(wrappedValue: ProfileViewModel(authService: auth, userId: nil))
    }
    @State private var feedLoadState: FeedLoadState = .idle
    @State private var feedPosts: [VKPost] = []
    @State private var feedProfiles: [VKProfile] = []
    @State private var feedGroups: [VKGroup] = []
    @State private var nextFrom: String? = nil       // курсор для подгрузки
    @State private var isLoadingMore: Bool = false  // подгрузка в конец
    @State private var commentsContext: PostCommentsContext? = nil
    /// Переопределения счётчика лайков после likes.add (postId -> новый count).
    @State private var postLikeOverrides: [String: Int] = [:]
    /// Переопределения «лайкнуто» после likes.add (postId -> true).
    @State private var postLikedOverrides: [String: Bool] = [:]
    @State private var likeInProgress: Set<String> = []  // postId, чтобы не дублировать запросы
    @State private var videoPlayerRequest: VideoPlayerRequest? = nil
    /// Переопределения опросов после голосования. Ключ: "ownerId_postId_pollId".
    @State private var pollVoteOverrides: [String: PollVoteOverride] = [:]
    @State private var pollVoteInProgress: Set<String> = []
    /// Переопределения счётчика репостов после wall.repost (postId -> count).
    @State private var postRepostOverrides: [String: Int] = [:]
    @State private var repostInProgress: Set<String> = []
    @State private var showRepostDMStub = false
    /// ID текущего пользователя (для показа «Удалить» только у своих постов). Заполняется при loadFeed.
    @State private var currentUserId: Int? = nil
    @State private var deleteInProgress: Set<String> = []
    @State private var pinInProgress: Set<String> = []
    /// Переопределение «закреплён» после wall.pin / wall.unpin (postId -> true/false).
    @State private var postPinnedOverrides: [String: Bool] = [:]
    /// Время последней успешной загрузки ленты — для авто-обновления только через 10 мин.
    @State private var lastFeedLoadDate: Date? = nil
    /// Инкремент при ручном «Обновить» — ScrollViewReader реагирует и прокручивает вверх.
    @State private var feedScrollToTopTrigger = 0
    /// Новые посты ожидают подтверждения пользователя (баннер «Показать N новых записей»).
    @State private var pendingFeedPosts: [VKPost] = []
    @State private var pendingFeedProfiles: [VKProfile] = []
    @State private var pendingFeedGroups: [VKGroup] = []
    @State private var pendingNextFrom: String? = nil
    @State private var pendingNewPostsCount: Int = 0

    private let vkApi = VKApiService()
    private let feedFilter = FeedFilter(blacklistKeywords: []) // позже — настройки

    @Environment(\.scenePhase) private var scenePhase

    /// Текущий активный раздел приложения (drawer-навигация)
    @State private var activeSection: AppSection = .feed
    /// Состояние бокового меню
    @State private var isDrawerOpen = false
    /// Количество непрочитанных сообщений для бейджа в drawer
    @State private var unreadMessagesCount = 0
    @AppStorage("setting_notifications") private var settingNotifications = true
    @AppStorage("setting_refresh_on_open") private var settingRefreshOnOpen = true

    var body: some View {
        Group {
            if case .authenticated = authService.state {
                ZStack(alignment: .leading) {
                    NavigationStack {
                        mainAppContent
                    }
                    .preferredColorScheme(.light)
                    .disabled(isDrawerOpen)

                    if isDrawerOpen {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.28)) { isDrawerOpen = false }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 10)
                                    .onEnded { v in
                                        if v.translation.width < -40 {
                                            withAnimation(.spring(duration: 0.28)) { isDrawerOpen = false }
                                        }
                                    }
                            )
                    }

                    DrawerMenuView(
                        profileViewModel: profileViewModel,
                        activeSection: $activeSection,
                        isOpen: $isDrawerOpen,
                        unreadMessagesCount: unreadMessagesCount
                    )
                    .frame(width: drawerWidth)
                    .offset(x: isDrawerOpen ? 0 : -drawerWidth)
                    .animation(.spring(duration: 0.28), value: isDrawerOpen)

                    if !isDrawerOpen {
                        Color.clear
                            .frame(width: 20)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                                    .onEnded { v in
                                        if v.translation.width > 30 && v.startLocation.x < 30 {
                                            withAnimation(.spring(duration: 0.28)) { isDrawerOpen = true }
                                        }
                                    }
                            )
                    }
                }
            } else {
                if hasCompletedOnboarding {
                    mainContentStack
                } else {
                    OnboardingView(authService: authService)
                }
            }
        }
        .sheet(isPresented: $showAuthView) {
            AuthView(authService: authService)
        }
        .onChange(of: authService.state) { _, state in
            if case .authenticated = state { hasCompletedOnboarding = true }
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active, case .authenticated = authService.state {
                let stale = lastFeedLoadDate.map { Date().timeIntervalSince($0) > 600 } ?? true
                if stale { loadFeed() }
            }
        }
    }

    @ViewBuilder
    private var mainAppContent: some View {
        switch activeSection {
        case .feed:
            feedSectionView
        case .friends:
            sectionView(FriendsTabView(authService: authService))
        case .messages:
            sectionView(MessagesTabView(authService: authService))
        case .profile:
            sectionView(ProfileView(authService: authService, viewModel: profileViewModel))
        case .groups:
            sectionView(groupsSectionView)
        case .photos:
            sectionView(photosSectionView)
        case .video:
            sectionView(stubView(title: "Видеозаписи", icon: "video"))
        case .audio:
            sectionView(stubView(title: "Аудиозаписи", icon: "music.note"))
        case .answers:
            sectionView(stubView(title: "Ответы", icon: "bell"))
        case .bookmarks:
            sectionView(stubView(title: "Закладки", icon: "bookmark"))
        case .search:
            sectionView(searchStubView)
        case .settings:
            sectionView(settingsStubView)
        }
    }

    /// Применяет синюю шапку VK и кнопку drawer ко всем секциям кроме ленты.
    private func sectionView<V: View>(_ view: V) -> some View {
        view
            .vkBlueNavBar()
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { feedDrawerButton } }
    }

    private var photosSectionView: some View {
        ProfilePhotoTabView(
            albums: profileViewModel.albums,
            loadState: profileViewModel.albumsLoadState,
            authService: authService,
            ownerId: profileViewModel.user?.id ?? 0,
            isOwnProfile: true,
            onRefresh: {
                if let uid = profileViewModel.user?.id {
                    await profileViewModel.loadAlbums(ownerId: uid, forceRefresh: true)
                }
            }
        )
        .navigationTitle("Фотографии")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let uid = profileViewModel.user?.id {
                Task { await profileViewModel.loadAlbums(ownerId: uid, forceRefresh: false) }
            }
        }
    }

    private var groupsSectionView: some View {
        ProfileGroupsTabView(
            groups: profileViewModel.groups,
            loadState: profileViewModel.groupsLoadState,
            authService: authService,
            onRefresh: { await profileViewModel.loadGroups(forceRefresh: true) },
            onLeaveSuccess: { Task { await profileViewModel.loadGroups(forceRefresh: true) } },
            embeddedInScroll: false
        )
        .navigationTitle("Группы")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await profileViewModel.loadGroups(forceRefresh: false) } }
    }

    private func stubView(title: String, icon: String) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text("Раздел в разработке"))
            .navigationTitle(title)
    }

    private var searchStubView: some View {
        ContentUnavailableView("Поиск", systemImage: "magnifyingglass", description: Text("Раздел в разработке"))
            .navigationTitle("Поиск")
    }

    private var settingsStubView: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    settingsAvatarView
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileViewModel.user?.displayName ?? "—")
                            .font(VKTheme.TextStyle.dialogName)
                            .foregroundStyle(VKTheme.Colors.textPrimary)
                        Text("Настройки профиля — в разработке")
                            .font(VKTheme.TextStyle.timestamp)
                            .foregroundStyle(VKTheme.Colors.textSecondary)
                    }
                }
            } header: {
                Text("Учётная запись")
            }

            Section {
                Toggle("Push-уведомления", isOn: $settingNotifications)
                    .tint(VKTheme.Colors.primary)
                Toggle("Обновлять при открытии", isOn: $settingRefreshOnOpen)
                    .tint(VKTheme.Colors.primary)
            } header: {
                Text("Основные")
            }

            Section {
                HStack {
                    Text("Версия")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(VKTheme.Colors.textSecondary)
                        .font(VKTheme.TextStyle.timestamp)
                }
                HStack {
                    Text("VKaif")
                    Spacer()
                    Text("Неофициальный клиент ВКонтакте")
                        .foregroundStyle(VKTheme.Colors.textSecondary)
                        .font(VKTheme.TextStyle.commentTimestamp)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("О приложении")
            }

            Section {
                Button(role: .destructive) {
                    authService.logout()
                    feedPosts = []
                    feedProfiles = []
                    feedGroups = []
                    nextFrom = nil
                    currentUserId = nil
                    pendingFeedPosts = []
                    pendingFeedProfiles = []
                    pendingFeedGroups = []
                    pendingNextFrom = nil
                    pendingNewPostsCount = 0
                    activeSection = .feed
                } label: {
                    Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var settingsAvatarView: some View {
        let size: CGFloat = 44
        if let urlStr = profileViewModel.user?.avatarURL, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(hex: "#C8C8C8")
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: VKTheme.Radius.button))
        } else {
            RoundedRectangle(cornerRadius: VKTheme.Radius.button)
                .fill(Color(hex: "#C8C8C8"))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.fill")
                        .foregroundStyle(.white)
                )
        }
    }

    private var feedSectionView: some View {
        Group {
            if !feedPosts.isEmpty {
                feedListView
            } else {
                mainContentStack
            }
        }
        .navigationTitle("Новости")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(VKTheme.Colors.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                feedDrawerButton
            }
        }
        .onAppear {
            if case .authenticated = authService.state, case .idle = feedLoadState {
                loadFeed()
            }
        }
    }

    private var feedDrawerButton: some View {
        Button {
            withAnimation(.spring(duration: 0.28)) { isDrawerOpen = true }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                if unreadMessagesCount > 0 {
                    Text(unreadMessagesCount > 99 ? "99+" : "\(unreadMessagesCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(VKTheme.Colors.badge)
                        .clipShape(Capsule())
                        .offset(x: 10, y: -8)
                }
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .tint(.white)
    }

    // MARK: - Лента постов (LazyVStack)

    private var feedListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("feedTop")
                    ForEach(feedPosts, id: \.postId) { post in
                        feedPostRow(post)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        Divider()
                    }

                    // Триггер подгрузки при достижении конца
                    if nextFrom != nil {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { loadMoreFeed() }
                    }

                    if isLoadingMore {
                        ProgressView("Ещё посты…")
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal)
                            .padding(.vertical, 16)
                    }
                }
            }
            .refreshable {
                feedScrollToTopTrigger += 1
                await loadFeed().value
            }
            .onChange(of: feedScrollToTopTrigger) { _, _ in
                withAnimation { proxy.scrollTo("feedTop", anchor: .top) }
            }
        }
        .navigationDestination(for: FeedDestination.self) { dest in
            switch dest {
            case .group(let id):
                GroupWallView(authService: authService, groupId: id)
            case .user(let id):
                ProfileViewWrapper(authService: authService, userId: id)
            }
        }
        .sheet(item: $commentsContext) { ctx in
            PostCommentsView(context: ctx, authService: authService)
        }
        .fullScreenCover(item: $videoPlayerRequest) { req in
            videoPlayerContent(req: req)
        }
        .overlay(alignment: .top) {
            if feedLoadState.isLoading {
                ProgressView("Загрузка…")
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
            }
        }
        .overlay(alignment: .top) {
            if pendingNewPostsCount > 0 && !feedLoadState.isLoading {
                Button { applyPendingFeed() } label: {
                    Text(newPostsBannerText(pendingNewPostsCount))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(VKTheme.Colors.primary)
                        .clipShape(Capsule())
                }
                .padding(.top, 8)
                .shadow(radius: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: pendingNewPostsCount)
            }
        }
        .alert("Репост в личку", isPresented: $showRepostDMStub) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Скоро. Раздел сообщений в разработке.")
        }
    }

    @ViewBuilder
    private func videoPlayerContent(req: VideoPlayerRequest) -> some View {
        let ctx: VideoPlayerPostContext? = req.post.map { p in
            VideoPlayerPostContext(
                likesCount: postLikeOverrides[p.postId] ?? p.likesCount,
                commentsCount: p.commentsCount,
                isLiked: postLikedOverrides[p.postId] ?? (p.likes?.userLikes == 1),
                onLike: { likeToggle(p) },
                onTapComments: {
                    commentsContext = PostCommentsContext(
                        ownerId: p.ownerId ?? p.fromId ?? 0,
                        postId: p.id,
                        totalCount: p.commentsCount
                    )
                }
            )
        }
        VideoPlayerView(url: req.url, onDismiss: { videoPlayerRequest = nil }, postContext: ctx)
    }

    private var mainContentStack: some View {
        VStack(spacing: 20) {
            Text("VKaif")
                .font(.largeTitle)
                .fontWeight(.bold)
            Divider()
            statusSection
            actionButtons
            feedResultView
        }
        .padding()
    }

    private func authorName(for post: VKPost) -> String {
        VKaif.authorName(for: post, profiles: feedProfiles, groups: feedGroups)
    }

    private func authorAvatarURL(for post: VKPost) -> String? {
        VKaif.authorAvatarURL(for: post, profiles: feedProfiles, groups: feedGroups)
    }

    private func feedDestination(for post: VKPost) -> FeedDestination? {
        guard let id = post.ownerId ?? post.fromId else { return nil }
        if id < 0 {
            return .group(id: abs(id))
        } else {
            return .user(id: id)
        }
    }

    private func feedPostRow(_ post: VKPost) -> some View {
        let ownerId = post.ownerId ?? post.fromId ?? 0
        let isOwnPost = ownerId > 0 && currentUserId != nil && ownerId == currentUserId
        let repostCount = postRepostOverrides[post.postId]
        let repostLoading = repostInProgress.contains(post.postId)
        let repostToWallAction: (() -> Void)? = repostLoading ? nil : { repostToWall(post) }
        let tapComments: () -> Void = {
            commentsContext = PostCommentsContext(
                ownerId: post.ownerId ?? post.fromId ?? 0,
                postId: post.id,
                totalCount: post.commentsCount
            )
        }
        let likeAction: (() -> Void)? = likeInProgress.contains(post.postId) ? nil : { likeToggle(post) }
        let tapVideo: (VKVideo, Int, VKPost) async -> Void = { video, ownerId, post in
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
                if let url { videoPlayerRequest = VideoPlayerRequest(url: url, post: post) }
            }
        }
        let onPollVoteAction: (VKPost, VKPoll, Int) -> Void = { p, poll, answerId in
            pollVote(post: p, poll: poll, answerId: answerId)
        }
        let onDeleteAction: (() -> Void)? = isOwnPost ? { deletePost(post) } : nil
        let deletePhotoClosure: (String, Int, Int) async -> Bool = { token, ownerId, photoId in
            await deletePhotoFromPost(token: token, ownerId: ownerId, photoId: photoId)
        }
        let makeProfilePhotoClosure: (String, Int, Int) async -> (Bool, String?) = { token, ownerId, photoId in
            await makeProfilePhotoFromPost(token: token, ownerId: ownerId, photoId: photoId)
        }
        let onDeletePhotoAction: ((String, Int, Int) async -> Bool)? = isOwnPost ? Optional(deletePhotoClosure) : nil
        let onMakeProfilePhotoAction: ((String, Int, Int) async -> (Bool, String?))? = isOwnPost ? Optional(makeProfilePhotoClosure) : nil
        return FeedPostRowCell(
            post: post,
            authorName: authorName(for: post),
            authorAvatarURL: authorAvatarURL(for: post),
            relativeDate: relativeDateString(from: post.date),
            profiles: feedProfiles,
            groups: feedGroups,
            authService: authService,
            feedDestination: feedDestination(for: post),
            onTapComments: tapComments,
            likesCountOverride: postLikeOverrides[post.postId],
            isLikedOverride: postLikedOverrides[post.postId],
            likeInProgress: likeInProgress.contains(post.postId),
            onLike: likeAction,
            onTapVideo: tapVideo,
            pollVoteOverrides: pollVoteOverrides,
            onPollVote: onPollVoteAction,
            pollVoteInProgress: pollVoteInProgress,
            repostsCountOverride: repostCount,
            onRepostToWall: repostToWallAction,
            onRepostToDM: { showRepostDMStub = true },
            repostInProgress: repostLoading,
            canDeletePost: isOwnPost,
            onDelete: onDeleteAction,
            deleteInProgress: deleteInProgress.contains(post.postId),
            canPinPost: isOwnPost,
            isPinned: postPinnedOverrides[post.postId] ?? (post.isPinned == 1),
            onPin: { pinPost(post) },
            onUnpin: { unpinPost(post) },
            pinInProgress: pinInProgress.contains(post.postId),
            onDeletePhoto: onDeletePhotoAction,
            onMakeProfilePhoto: onMakeProfilePhotoAction,
            onRepostSuccessFromGallery: { newCount in postRepostOverrides[post.postId] = newCount },
            vkApi: vkApi,
            getAccessToken: { authService.accessToken ?? "" }
        )
    }

    /// Сделать фото главным в профиле (photos.makeCover). Для своих постов из fullscreen галереи.
    private func makeProfilePhotoFromPost(token: String, ownerId: Int, photoId: Int) async -> (Bool, String?) {
        do {
            try await vkApi.photosMakeCover(token: token, ownerId: ownerId, photoId: photoId, albumId: -6)
            return (true, nil)
        } catch {
            AppLogger.shared.error("Feed", "makeProfilePhoto failed", error: error)
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Удаление фото (photos.delete). Для своих постов из fullscreen галереи. Возвращает true при успехе.
    private func deletePhotoFromPost(token: String, ownerId: Int, photoId: Int) async -> Bool {
        do {
            try await vkApi.photosDelete(token: token, ownerId: ownerId, photoId: photoId)
            return true
        } catch {
            return false
        }
    }

    /// Удаление поста (wall.delete). При успехе пост убирается из ленты.
    private func deletePost(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let ownerId = post.ownerId ?? post.fromId ?? 0
        guard ownerId != 0 else { return }
        let pid = post.postId
        if deleteInProgress.contains(pid) { return }
        deleteInProgress.insert(pid)
        Task {
            do {
                try await vkApi.wallDelete(token: token, ownerId: ownerId, postId: post.id)
                await MainActor.run {
                    feedPosts.removeAll { $0.postId == pid }
                    deleteInProgress.remove(pid)
                }
            } catch {
                await MainActor.run { deleteInProgress.remove(pid) }
            }
        }
    }

    /// Закрепить пост (wall.pin). Только свои посты.
    private func pinPost(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let ownerId = post.ownerId ?? post.fromId ?? 0
        guard ownerId != 0 else { return }
        let pid = post.postId
        if pinInProgress.contains(pid) { return }
        pinInProgress.insert(pid)
        Task {
            do {
                try await vkApi.wallPin(token: token, ownerId: ownerId, postId: post.id)
                await MainActor.run {
                    postPinnedOverrides[pid] = true
                    pinInProgress.remove(pid)
                }
            } catch {
                await MainActor.run { pinInProgress.remove(pid) }
            }
        }
    }

    /// Открепить пост (wall.unpin).
    private func unpinPost(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let ownerId = post.ownerId ?? post.fromId ?? 0
        guard ownerId != 0 else { return }
        let pid = post.postId
        if pinInProgress.contains(pid) { return }
        pinInProgress.insert(pid)
        Task {
            do {
                try await vkApi.wallUnpin(token: token, ownerId: ownerId, postId: post.id)
                await MainActor.run {
                    postPinnedOverrides[pid] = false
                    pinInProgress.remove(pid)
                }
            } catch {
                await MainActor.run { pinInProgress.remove(pid) }
            }
        }
    }

    // MARK: - Views

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Статус авторизации:")
                .font(.headline)

            switch authService.state {
            case .idle:
                Label("Не авторизован", systemImage: "person.slash")
                    .foregroundColor(.secondary)
            case .authenticating:
                Label("Авторизация...", systemImage: "arrow.clockwise")
                    .foregroundColor(.blue)
            case .authenticated:
                Label("Авторизован ✓", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                if let token = authService.accessToken {
                    Text("Токен: \(String(token.prefix(20)))...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .failed(let error):
                Label("Ошибка: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if case .authenticated = authService.state {
                Button(action: { loadFeed() }) {
                    Label(
                        feedLoadState.isLoading ? "Загрузка…" : "Загрузить ленту",
                        systemImage: "list.bullet.rectangle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(feedLoadState.isLoading)

                Button(action: authService.logout) {
                    Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button(action: {
                    authService.startAuthentication()
                    showAuthView = true
                }) {
                    Label("Войти через ВКонтакте", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var feedResultView: some View {
        switch feedLoadState {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView("Загрузка ленты…")
        case .loaded(let count):
            Label("Загружено постов: \(count)", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let error):
            Label("Ошибка: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.caption)
        }
    }

    // MARK: - Загрузка ленты

    /// Первая загрузка или обновление. При наличии постов новые идут в pending (баннер), при пустой ленте — прямо.
    @discardableResult
    private func loadFeed() -> Task<Void, Never> {
        guard let token = authService.accessToken else { return Task {} }
        let isInitialLoad = feedPosts.isEmpty
        let existingIds = Set(feedPosts.map(\.postId))
        feedLoadState = .loading
        return Task {
            do {
                let response = try await vkApi.getNewsfeed(token: token)
                let filtered = feedFilter.filter(response.items)
                if response.items.count != filtered.count {
                    print("[VKaif] Фильтр: было \(response.items.count), осталось \(filtered.count)")
                }
                if await MainActor.run(body: { currentUserId }) == nil,
                   let users = try? await vkApi.getUsers(token: token),
                   let first = users.first {
                    await MainActor.run { currentUserId = first.id }
                }
                let enriched = await enrichPhotoStubs(in: filtered, token: token)
                if isInitialLoad {
                    await MainActor.run {
                        feedPosts = enriched
                        feedProfiles = response.profiles ?? []
                        feedGroups = response.groups ?? []
                        nextFrom = response.nextFrom
                        feedLoadState = .loaded(count: enriched.count)
                        lastFeedLoadDate = Date()
                    }
                } else {
                    let newCount = enriched.filter { !existingIds.contains($0.postId) }.count
                    if newCount == 0 {
                        await MainActor.run {
                            feedPosts = enriched
                            feedProfiles = response.profiles ?? []
                            feedGroups = response.groups ?? []
                            nextFrom = response.nextFrom
                            feedLoadState = .loaded(count: enriched.count)
                            lastFeedLoadDate = Date()
                        }
                    } else {
                        await MainActor.run {
                            pendingFeedPosts = enriched
                            pendingFeedProfiles = response.profiles ?? []
                            pendingFeedGroups = response.groups ?? []
                            pendingNextFrom = response.nextFrom
                            pendingNewPostsCount = newCount
                            feedLoadState = .loaded(count: enriched.count)
                            lastFeedLoadDate = Date()
                        }
                    }
                }
                if let counters = try? await vkApi.getAccountCounters(token: token) {
                    await MainActor.run { unreadMessagesCount = counters.messages ?? 0 }
                }
                printFeedToConsole(posts: enriched, nextFrom: response.nextFrom)
            } catch {
                await MainActor.run {
                    feedLoadState = .failed(error)
                }
            }
        }
    }

    /// Применяет отложенные посты из pending и прокручивает вверх.
    private func applyPendingFeed() {
        guard !pendingFeedPosts.isEmpty else { return }
        feedPosts = pendingFeedPosts
        feedProfiles = pendingFeedProfiles
        feedGroups = pendingFeedGroups
        nextFrom = pendingNextFrom
        pendingFeedPosts = []
        pendingFeedProfiles = []
        pendingFeedGroups = []
        pendingNextFrom = nil
        pendingNewPostsCount = 0
        feedScrollToTopTrigger += 1
    }

    private func newPostsBannerText(_ count: Int) -> String {
        let n = count % 100
        let suffix: String
        if (11...14).contains(n) {
            suffix = "новых записей"
        } else {
            switch n % 10 {
            case 1: suffix = "новую запись"
            case 2, 3, 4: suffix = "новые записи"
            default: suffix = "новых записей"
            }
        }
        return "Показать \(count) \(suffix)"
    }

    /// Подгрузка следующей страницы в конец ленты.
    private func loadMoreFeed() {
        guard let token = authService.accessToken,
              let from = nextFrom,
              !from.isEmpty,
              !feedLoadState.isLoading,
              !isLoadingMore else { return }
        isLoadingMore = true
        Task {
            do {
                let response = try await vkApi.getNewsfeed(token: token, startFrom: from)
                let filtered = feedFilter.filter(response.items)
                let enriched = await enrichPhotoStubs(in: filtered, token: token)
                await MainActor.run {
                    feedPosts.append(contentsOf: enriched)
                    mergeProfiles(response.profiles ?? [])
                    mergeGroups(response.groups ?? [])
                    nextFrom = response.nextFrom
                    isLoadingMore = false
                }
                if !enriched.isEmpty {
                    print("[VKaif] Подгружено ещё \(enriched.count) постов, next_from: \(response.nextFrom ?? "nil")")
                }
            } catch {
                await MainActor.run {
                    isLoadingMore = false
                }
            }
        }
    }

    private func mergeProfiles(_ new: [VKProfile]) {
        let existingIds = Set(feedProfiles.map(\.id))
        let toAdd = new.filter { !existingIds.contains($0.id) }
        if !toAdd.isEmpty { feedProfiles.append(contentsOf: toAdd) }
    }

    private func mergeGroups(_ new: [VKGroup]) {
        let existingIds = Set(feedGroups.map(\.id))
        let toAdd = new.filter { !existingIds.contains($0.id) }
        if !toAdd.isEmpty { feedGroups.append(contentsOf: toAdd) }
    }

    /// Toggle лайка поста: если уже лайкнут — likes.delete, иначе likes.add.
    private func likeToggle(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let ownerId = post.ownerId ?? post.fromId ?? 0
        guard ownerId != 0 else { return }
        let pid = post.postId
        if likeInProgress.contains(pid) { return }
        let isLiked = postLikedOverrides[pid] ?? (post.likes?.userLikes == 1)
        likeInProgress.insert(pid)
        Task {
            do {
                let newCount: Int
                if isLiked {
                    newCount = try await vkApi.likesDelete(
                        token: token,
                        type: "post",
                        ownerId: ownerId,
                        itemId: post.id
                    )
                    await MainActor.run {
                        postLikeOverrides[pid] = newCount
                        postLikedOverrides[pid] = false
                        likeInProgress.remove(pid)
                    }
                } else {
                    newCount = try await vkApi.likesAdd(
                        token: token,
                        type: "post",
                        ownerId: ownerId,
                        itemId: post.id
                    )
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

    /// Репост поста на свою стену (wall.repost). object = "wall{owner_id}_{post_id}".
    private func repostToWall(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let ownerId = post.ownerId ?? post.fromId ?? 0
        guard ownerId != 0 else { return }
        let pid = post.postId
        if repostInProgress.contains(pid) { return }
        repostInProgress.insert(pid)
        let object = "wall\(ownerId)_\(post.id)"
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

    private func pollVote(post: VKPost, poll: VKPoll, answerId: Int) {
        guard let token = authService.accessToken else { return }
        let ownerId = poll.ownerId ?? post.ownerId ?? post.fromId ?? 0
        guard ownerId != 0 else { return }
        let key = "\(ownerId)_\(post.id)_\(poll.id)"
        if pollVoteInProgress.contains(key) { return }
        pollVoteInProgress.insert(key)
        Task {
            do {
                try await vkApi.addPollVote(
                    token: token,
                    ownerId: ownerId,
                    pollId: poll.id,
                    answerId: answerId
                )
                let totalBefore = poll.votes ?? 0
                let totalVotes = totalBefore + 1
                var answerVotes: [Int: Int] = [:]
                for a in poll.answers ?? [] {
                    let v = a.votes ?? 0
                    answerVotes[a.id] = a.id == answerId ? v + 1 : v
                }
                await MainActor.run {
                    pollVoteOverrides[key] = PollVoteOverride(
                        selectedAnswerId: answerId,
                        totalVotes: totalVotes,
                        answerVotes: answerVotes
                    )
                    pollVoteInProgress.remove(key)
                }
            } catch {
                await MainActor.run { pollVoteInProgress.remove(key) }
            }
        }
    }

    private func addPhotoToSaved(token: String, ownerId: Int, photoId: Int, accessKey: String? = nil) async -> Bool {
        let t = token
        let o = ownerId
        let p = photoId
        let a = accessKey ?? ""
        guard !t.isEmpty else {
            AppLogger.shared.error("Gallery", "addPhotoToSaved: empty token")
            return false
        }
        do {
            _ = try await vkApi.photosCopy(token: t, ownerId: o, photoId: p, accessKey: a)
            return true
        } catch {
            AppLogger.shared.error("Gallery", "addPhotoToSaved failed ownerId=\(o) photoId=\(p)", error: error)
            return false
        }
    }

    /// Обогащает посты: находит фото-стабы (нет sizes и нет photo_xxx) и подгружает их через photos.getById.
    /// Максимум 1000 фото за вызов (лимит VK). Если запрос упал — возвращает исходный список без паники.
    private func enrichPhotoStubs(in posts: [VKPost], token: String) async -> [VKPost] {
        // Собираем стабы: photo с id+ownerId, но без URL
        var stubRefs: [(ownerId: Int, photoId: Int, accessKey: String?)] = []
        for post in posts {
            for att in (post.attachments ?? []) {
                guard let photo = att.photo else { continue }
                guard photo.feedPreviewURL == nil else { continue }
                let ownerId = photo.ownerId ?? 0
                guard ownerId != 0 else { continue }
                stubRefs.append((ownerId: ownerId, photoId: photo.id, accessKey: photo.accessKey))
            }
            // Репосты тоже проверяем
            for repost in (post.copyHistory ?? []) {
                for att in (repost.attachments ?? []) {
                    guard let photo = att.photo else { continue }
                    guard photo.feedPreviewURL == nil else { continue }
                    let ownerId = photo.ownerId ?? 0
                    guard ownerId != 0 else { continue }
                    stubRefs.append((ownerId: ownerId, photoId: photo.id, accessKey: photo.accessKey))
                }
            }
        }
        guard !stubRefs.isEmpty else { return posts }

        // Дедупликация
        var seen = Set<String>()
        stubRefs = stubRefs.filter { ref in
            let key = "\(ref.ownerId)_\(ref.photoId)"
            return seen.insert(key).inserted
        }
        // Ограничение VK: max 1000 за запрос
        let batch = Array(stubRefs.prefix(1000))
        print("[VKaif] enrichPhotoStubs: stub photos=\(stubRefs.count), fetching \(batch.count)")

        guard let enrichedPhotos = try? await vkApi.photosGetById(token: token, photoRefs: batch) else {
            return posts
        }
        var enrichMap: [String: VKPhoto] = [:]
        for p in enrichedPhotos {
            guard let oid = p.ownerId else { continue }
            enrichMap["\(oid)_\(p.id)"] = p
        }
        print("[VKaif] enrichPhotoStubs: received \(enrichedPhotos.count) photos")

        // Заменяем стабы на полные фото в копиях постов
        return posts.map { post in
            var p = post
            p.attachments = post.attachments?.map { att in
                var a = att
                if let photo = att.photo,
                   photo.feedPreviewURL == nil,
                   let full = enrichMap["\(photo.ownerId ?? 0)_\(photo.id)"] {
                    a.photo = full
                }
                return a
            }
            return p
        }
    }

    private func printFeedToConsole(posts: [VKPost], nextFrom: String?) {
        print("[VKaif] ——— Лента (после фильтра): \(posts.count) постов ———")
        for (i, post) in posts.enumerated() {
            let preview = String(post.text.prefix(60))
            let more = post.text.count > 60 ? "…" : ""
            print("[\(i + 1)] \(preview)\(more) | date=\(post.date)")
        }
        if let next = nextFrom {
            print("next_from: \(next)")
        }
        print("[VKaif] ——— конец ленты ———")
    }
}

// MARK: - Состояние загрузки ленты

enum FeedLoadState {
    case idle
    case loading
    case loaded(count: Int)
    case failed(Error)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - Разделы приложения (drawer-навигация)

enum AppSection {
    case feed, friends, messages, profile, groups, photos, video, audio, answers, bookmarks, search, settings
}

#Preview {
    ContentView()
}
