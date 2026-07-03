import SwiftUI

// MARK: - Вкладка «Стена»: посты на стене пользователя (wall.get)

struct ProfileWallTabView: View {
    let posts: [VKPost]
    var profiles: [VKProfile] = []
    var groups: [VKGroup] = []
    let loadState: ProfileTabLoadState
    let user: VKUserDetail
    @ObservedObject var authService: AuthService
    /// true = стена текущего пользователя (показывать меню «Удалить» у постов).
    var isOwnProfile: Bool = false
    /// После успешного wall.delete — убрать пост из списка. nil = не показывать удаление.
    var onDeletePost: ((VKPost) -> Void)? = nil
    var onRefresh: () async -> Void
    /// true = контент встроен во внешний ScrollView (header + посты скроллятся вместе).
    var embeddedInScroll: Bool = false

    @State private var commentsContext: PostCommentsContext? = nil
    @State private var deleteInProgress: Set<String> = []
    @State private var pinInProgress: Set<String> = []
    @State private var postPinnedOverrides: [String: Bool] = [:]
    @State private var postLikeOverrides: [String: Int] = [:]
    @State private var postLikedOverrides: [String: Bool] = [:]
    @State private var likeInProgress: Set<String> = []
    @State private var postRepostOverrides: [String: Int] = [:]
    @State private var repostInProgress: Set<String> = []
    @State private var showRepostDMStub = false
    @State private var videoPlayerURL: URL? = nil
    @State private var videoPlayerPost: VKPost? = nil

    private let vkApi = VKApiService()
    private var ownerId: Int { user.id }

    var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Загрузка стены…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if posts.isEmpty {
                    ContentUnavailableView("Нет записей", systemImage: "doc.text")
                } else {
                    let wallContent = LazyVStack(spacing: 0) {
                        ForEach(posts, id: \.postId) { post in
                            profileWallPostRow(post)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemBackground))
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                    if embeddedInScroll {
                        wallContent
                    } else {
                        ScrollView { wallContent }
                    }
                }
            case .failed(let error):
                ContentUnavailableView(
                    "Ошибка загрузки стены",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(error.localizedDescription)
                )
            }
        }
        .refreshable { await onRefresh() }
        .sheet(item: $commentsContext) { ctx in
            PostCommentsView(context: ctx, authService: authService)
        }
        .fullScreenCover(isPresented: Binding(
            get: { videoPlayerURL != nil },
            set: { if !$0 { videoPlayerURL = nil; videoPlayerPost = nil } }
        )) {
            if let url = videoPlayerURL {
                profileWallVideoPlayerContent(url: url)
            }
        }
        .alert("Репост в личку", isPresented: $showRepostDMStub) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Скоро. Раздел сообщений в разработке.")
        }
    }

    @ViewBuilder
    private func profileWallVideoPlayerContent(url: URL) -> some View {
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

    private func profileWallPostRow(_ post: VKPost) -> some View {
        let repostCount = postRepostOverrides[post.postId]
        let repostLoading = repostInProgress.contains(post.postId)
        let repostToWallAction: (() -> Void)? = repostLoading ? nil : { repostToWall(post) }
        let cell = ProfileWallPostCell(
            post: post,
            user: user,
            profiles: profiles,
            groups: groups,
            authService: authService,
            ownerId: ownerId,
            isOwnProfile: isOwnProfile,
            onDeletePost: onDeletePost,
            commentsContext: $commentsContext,
            postLikeOverrides: postLikeOverrides[post.postId],
            postLikedOverrides: postLikedOverrides[post.postId],
            likeInProgress: likeInProgress.contains(post.postId),
            repostCount: repostCount,
            repostLoading: repostLoading,
            deleteInProgress: deleteInProgress.contains(post.postId),
            onTapComments: {
                commentsContext = PostCommentsContext(
                    ownerId: post.ownerId ?? ownerId,
                    postId: post.id,
                    totalCount: post.commentsCount
                )
            },
            onLike: { likeToggle(post) },
            onTapVideo: { video, videoOwnerId, post in
                var url: URL?
                if let p = video.player, let u = URL(string: p) {
                    url = u
                } else {
                    let token = await MainActor.run { authService.accessToken } ?? ""
                    if !token.isEmpty,
                       let res = try? await vkApi.getVideo(token: token, videos: video.videoGetId(ownerFallback: videoOwnerId)),
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
            onRepostToWall: { repostToWall(post) },
            onRepostDM: { showRepostDMStub = true },
            onRepostSuccessFromGallery: { newCount in postRepostOverrides[post.postId] = newCount },
            onDelete: { deletePost(post) },
            onPin: isOwnProfile ? { pinPost(post) } : nil,
            onUnpin: isOwnProfile ? { unpinPost(post) } : nil,
            isPinned: postPinnedOverrides[post.postId] ?? (post.isPinned == 1),
            pinInProgress: pinInProgress.contains(post.postId),
            onDeletePhoto: { token, oid, pid in await deletePhotoFromPost(token: token, ownerId: oid, photoId: pid) },
            onMakeProfilePhoto: { token, oid, pid in await makeProfilePhoto(token: token, ownerId: oid, photoId: pid) },
            vkApi: vkApi,
            getAccessToken: { authService.accessToken ?? "" }
        )
        return cell
    }

    private func deletePost(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let oid = post.ownerId ?? post.fromId ?? ownerId
        let pid = post.postId
        if deleteInProgress.contains(pid) { return }
        deleteInProgress.insert(pid)
        Task {
            do {
                try await vkApi.wallDelete(token: token, ownerId: oid, postId: post.id)
                await MainActor.run {
                    onDeletePost?(post)
                    deleteInProgress.remove(pid)
                }
            } catch {
                await MainActor.run { deleteInProgress.remove(pid) }
            }
        }
    }

    private func pinPost(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let oid = post.ownerId ?? post.fromId ?? ownerId
        let pid = post.postId
        if pinInProgress.contains(pid) { return }
        pinInProgress.insert(pid)
        Task {
            do {
                try await vkApi.wallPin(token: token, ownerId: oid, postId: post.id)
                await MainActor.run {
                    postPinnedOverrides[pid] = true
                    pinInProgress.remove(pid)
                }
            } catch {
                await MainActor.run { pinInProgress.remove(pid) }
            }
        }
    }

    private func unpinPost(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let oid = post.ownerId ?? post.fromId ?? ownerId
        let pid = post.postId
        if pinInProgress.contains(pid) { return }
        pinInProgress.insert(pid)
        Task {
            do {
                try await vkApi.wallUnpin(token: token, ownerId: oid, postId: post.id)
                await MainActor.run {
                    postPinnedOverrides[pid] = false
                    pinInProgress.remove(pid)
                }
            } catch {
                await MainActor.run { pinInProgress.remove(pid) }
            }
        }
    }

    private func likeToggle(_ post: VKPost) {
        guard let token = authService.accessToken else { return }
        let wallOwnerId = post.ownerId ?? ownerId
        let pid = post.postId
        if likeInProgress.contains(pid) { return }
        let isLiked = postLikedOverrides[pid] ?? (post.likes?.userLikes == 1)
        likeInProgress.insert(pid)
        Task {
            do {
                let newCount: Int
                if isLiked {
                    newCount = try await vkApi.likesDelete(token: token, type: "post", ownerId: wallOwnerId, itemId: post.id)
                    await MainActor.run {
                        postLikeOverrides[pid] = newCount
                        postLikedOverrides[pid] = false
                        likeInProgress.remove(pid)
                    }
                } else {
                    newCount = try await vkApi.likesAdd(token: token, type: "post", ownerId: wallOwnerId, itemId: post.id)
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

    private func deletePhotoFromPost(token: String, ownerId: Int, photoId: Int) async -> Bool {
        guard !token.isEmpty else { return false }
        do {
            try await vkApi.photosDelete(token: token, ownerId: ownerId, photoId: photoId)
            return true
        } catch {
            return false
        }
    }

    private func makeProfilePhoto(token: String, ownerId: Int, photoId: Int) async -> (Bool, String?) {
        guard !token.isEmpty else { return (false, "Нет токена доступа") }
        do {
            try await vkApi.photosMakeCover(token: token, ownerId: ownerId, photoId: photoId, albumId: -6)
            return (true, nil)
        } catch {
            AppLogger.shared.error("ProfileWall", "makeProfilePhoto failed", error: error)
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

// MARK: - Вкладка «Фото»: альбомы + Сохранённые (данные передаются из ProfileView)

struct ProfilePhotoTabView: View {
    let albums: [VKAlbum]
    let loadState: ProfileTabLoadState
    @ObservedObject var authService: AuthService
    let ownerId: Int
    /// true = свой профиль (в альбоме «Фото профиля» показывать «Сделать фото профиля»).
    var isOwnProfile: Bool = false
    var onRefresh: () async -> Void

    private static let savedAlbumId = -15
    /// VK: фото профиля (стена).
    private static let profileAlbumId = -6

    var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Загрузка альбомов…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                List {
                    Section {
                        NavigationLink(value: AlbumDestination(ownerId: ownerId, albumId: Self.savedAlbumId, title: "Сохранённые фото", isOwnProfile: isOwnProfile)) {
                            Label("Сохранённые фото", systemImage: "square.and.arrow.down.fill")
                        }
                        NavigationLink(value: AlbumDestination(ownerId: ownerId, albumId: Self.profileAlbumId, title: "Фото профиля", isOwnProfile: isOwnProfile)) {
                            Label("Фото профиля", systemImage: "person.crop.rectangle.stack")
                        }
                    }
                    Section("Альбомы") {
                        ForEach(albums, id: \.id) { album in
                            NavigationLink(value: AlbumDestination(ownerId: ownerId, albumId: album.id, title: album.title, isOwnProfile: isOwnProfile)) {
                                HStack(spacing: 12) {
                                    albumThumb(album)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.body)
                                        Text("\(album.size) фото")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            case .failed(let error):
                ContentUnavailableView(
                    "Ошибка загрузки альбомов",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text("\(error.localizedDescription)\n\nПерелогиньтесь (Выйти → Войти) и выдайте права: друзья, фото, группы.")
                )
            }
        }
        .refreshable { await onRefresh() }
        .navigationDestination(for: AlbumDestination.self) { dest in
            AlbumPhotosView(
                authService: authService,
                ownerId: dest.ownerId,
                albumId: dest.albumId,
                albumTitle: dest.title,
                isOwnProfile: dest.isOwnProfile,
                onAlbumListChanged: onRefresh
            )
        }
    }

    private func albumThumb(_ album: VKAlbum) -> some View {
        Group {
            if let urlString = album.thumbURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure, .empty: Image(systemName: "photo").resizable().scaledToFit().foregroundStyle(.secondary)
                    @unknown default: EmptyView()
                    }
                }
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .clipped()
        .cornerRadius(8)
    }
}

struct AlbumDestination: Hashable {
    let ownerId: Int
    let albumId: Int
    let title: String
    /// true = альбом своего профиля (показывать «Сделать фото профиля» в альбоме -6).
    let isOwnProfile: Bool
}

/// Цель навигации из вкладки «Группы» профиля (отдельно от Int для друзей).
struct GroupDestination: Hashable {
    let groupId: Int
}

// MARK: - Вкладка «Друзья» (данные передаются из ProfileView)

struct ProfileFriendsTabView: View {
    let friends: [VKFriend]
    let loadState: ProfileTabLoadState
    @ObservedObject var authService: AuthService
    var onRefresh: () async -> Void
    /// true = контент встроен во внешний ScrollView (профиль), скролл один на весь экран.
    var embeddedInScroll: Bool = false

    @State private var searchText = ""

    private var filteredFriends: [VKFriend] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return friends }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return friends.filter { $0.displayName.lowercased().contains(query) }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Поиск по имени", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
    }

    var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Загрузка друзей…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if friends.isEmpty {
                    ContentUnavailableView("Нет друзей", systemImage: "person.2")
                } else if embeddedInScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        searchRow
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                        LazyVStack(spacing: 0) {
                            ForEach(filteredFriends, id: \.id) { friend in
                                NavigationLink(value: friend.id) {
                                    HStack(spacing: 12) {
                                        friendAvatar(friend)
                                        Text(friend.displayName)
                                            .font(.body)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                }
                                Divider()
                                    .padding(.leading, 44 + 12)
                            }
                        }
                        .background(Color(.systemBackground))
                    }
                    .navigationDestination(for: Int.self) { friendId in
                        ProfileViewWrapper(authService: authService, userId: friendId)
                    }
                } else {
                    VStack(spacing: 0) {
                        searchRow
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredFriends, id: \.id) { friend in
                                    NavigationLink(value: friend.id) {
                                        HStack(spacing: 12) {
                                            friendAvatar(friend)
                                            Text(friend.displayName)
                                                .font(.body)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 12)
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                        .padding(.leading, 44 + 12)
                                }
                            }
                        }
                        .refreshable { await onRefresh() }
                    }
                    .frame(maxHeight: .infinity)
                    .navigationDestination(for: Int.self) { friendId in
                        ProfileViewWrapper(authService: authService, userId: friendId)
                    }
                }
            case .failed(let error):
                ContentUnavailableView(
                    "Ошибка загрузки друзей",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text("\(error.localizedDescription)\n\nПерелогиньтесь (Выйти → Войти) и выдайте права: друзья, фото, группы.")
                )
            }
        }
        .refreshable { await onRefresh() }
    }

    private func friendAvatar(_ friend: VKFriend) -> some View {
        Group {
            if let urlString = friend.photo50, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure, .empty: Image(systemName: "person.circle.fill").resizable().foregroundStyle(.secondary)
                    @unknown default: EmptyView()
                    }
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Вкладка «Группы» (данные передаются из ProfileView)

struct ProfileGroupsTabView: View {
    let groups: [VKGroup]
    let loadState: ProfileTabLoadState
    @ObservedObject var authService: AuthService
    var onRefresh: () async -> Void
    /// Вызывается после успешной отписки в GroupWallView — обновить список групп.
    var onLeaveSuccess: (() -> Void)? = nil
    /// true = контент встроен во внешний ScrollView (профиль), скролл один на весь экран.
    var embeddedInScroll: Bool = false

    @State private var searchText = ""

    private var filteredGroups: [VKGroup] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return groups }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return groups.filter { (($0.name ?? "").lowercased().contains(query)) }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Поиск по названию", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
    }

    var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Загрузка групп…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if groups.isEmpty {
                    ContentUnavailableView("Нет групп", systemImage: "person.3")
                } else if embeddedInScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        searchRow
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                        LazyVStack(spacing: 0) {
                            ForEach(filteredGroups, id: \.id) { group in
                                NavigationLink(value: GroupDestination(groupId: group.id)) {
                                    groupRow(group)
                                }
                                Divider()
                                    .padding(.leading, 12 + 48 + 12)
                            }
                        }
                        .background(Color(.systemBackground))
                    }
                    .navigationDestination(for: GroupDestination.self) { dest in
                        GroupWallView(authService: authService, groupId: dest.groupId, onLeaveSuccess: onLeaveSuccess)
                    }
                } else {
                    VStack(spacing: 0) {
                        // Счётчик "N СООБЩЕСТВ"
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                Text("\(groups.count) СООБЩЕСТВ".uppercased())
                                    .font(VKTheme.TextStyle.sectionHeader)
                                    .foregroundStyle(VKTheme.Colors.primary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                Rectangle()
                                    .fill(VKTheme.Colors.primary)
                                    .frame(height: 2)
                            }
                            Spacer(minLength: 0)
                        }
                        Divider()

                        // Поиск
                        searchRow
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray6))
                        Divider()

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredGroups, id: \.id) { group in
                                    NavigationLink(value: GroupDestination(groupId: group.id)) {
                                        groupRow(group)
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                        .padding(.leading, 12 + 48 + 12)
                                }
                            }
                        }
                        .background(Color.white)
                        .refreshable { await onRefresh() }
                    }
                    .frame(maxHeight: .infinity)
                    .navigationDestination(for: GroupDestination.self) { dest in
                        GroupWallView(authService: authService, groupId: dest.groupId, onLeaveSuccess: onLeaveSuccess)
                    }
                }
            case .failed(let error):
                ContentUnavailableView(
                    "Ошибка загрузки групп",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text("\(error.localizedDescription)\n\nПерелогиньтесь (Выйти → Войти) и выдайте права: друзья, фото, группы.")
                )
            }
        }
        .refreshable { await onRefresh() }
    }

    private func groupRow(_ group: VKGroup) -> some View {
        HStack(spacing: 12) {
            groupAvatar(group)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name ?? "Группа \(group.id)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VKTheme.Colors.textPrimary)
                    .lineLimit(1)
                if let activity = group.activity, !activity.isEmpty {
                    Text(activity)
                        .font(VKTheme.TextStyle.timestamp)
                        .foregroundColor(VKTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
        .contentShape(Rectangle())
    }

    private func groupAvatar(_ group: VKGroup) -> some View {
        Group {
            if let urlString = group.photo50, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure, .empty: Image(systemName: "person.3.fill").resizable().foregroundStyle(.secondary)
                    @unknown default: EmptyView()
                    }
                }
            } else {
                Image(systemName: "person.3.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: VKTheme.AvatarSize.dialog, height: VKTheme.AvatarSize.dialog)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

enum ProfileTabLoadState {
    case idle
    case loading
    case loaded
    case failed(Error)
}
