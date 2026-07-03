import SwiftUI
import SafariServices

// MARK: - Встроенный браузер (SFSafariViewController)

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Переопределение опроса после голосования (оптимистичное отображение)

/// Состояние опроса после успешного голоса: выбранный вариант и обновлённые счётчики.
struct PollVoteOverride {
    let selectedAnswerId: Int
    let totalVotes: Int
    let answerVotes: [Int: Int]
}

// MARK: - Ячейка поста ленты


/// Заголовок: аватар, имя, относительная дата. Тело: текст с «Показать ещё». Медиа: сетка фото (1–10).
struct PostCellView: View {

    let post: VKPost
    let authorName: String
    let authorAvatarURL: String?
    let relativeDate: String
    /// Календарная дата поста (например "15 янв 2025"). nil = не показывать.
    var calendarDate: String? = nil
    /// Для разрешения автора репоста (copy_history). На стене группы — из wall.get extended=1.
    var profiles: [VKProfile] = []
    var groups: [VKGroup] = []
    /// Для навигации из ленты: тап по автору → группа/профиль. nil в превью или на стене группы.
    var authService: AuthService? = nil
    var feedDestination: FeedDestination? = nil
    /// Тап по счётчику комментариев → открыть экран комментариев. nil = не открывать.
    var onTapComments: (() -> Void)? = nil
    /// Переопределение счётчика лайков (после likes.add). nil = брать из post.
    var likesCountOverride: Int? = nil
    /// Переопределение «лайкнуто» (после likes.add). nil = из post.likes?.userLikes.
    var isLikedOverride: Bool? = nil
    /// Тап по лайку → поставить лайк. nil = только отображение.
    var onLike: (() -> Void)? = nil
    /// true = запрос лайка в процессе, кнопку не нажимать.
    var likeInProgress: Bool = false
    /// Тап по видео → загрузка player URL и открытие плеера. Передаётся пост для панели лайков/комментариев.
    var onTapVideo: ((VKVideo, Int, VKPost) async -> Void)? = nil
    /// Переопределения опросов после голосования. Ключ: "ownerId_postId_pollId".
    var pollVoteOverrides: [String: PollVoteOverride]? = nil
    /// Тап по варианту опроса → голос. (post, poll, answerId). nil = только отображение.
    var onPollVote: ((VKPost, VKPoll, Int) -> Void)? = nil
    /// Ключи опросов, по которым идёт запрос голоса (блокируем повторный тап).
    var pollVoteInProgress: Set<String> = []
    /// Переопределение счётчика репостов (после wall.repost). nil = из post.
    var repostsCountOverride: Int? = nil
    /// Репост на свою стену. nil = только отображение счётчика.
    var onRepostToWall: (() -> Void)? = nil
    /// Репост в личку (заглушка: показать «Скоро»). nil = не показывать пункт.
    var onRepostToDM: (() -> Void)? = nil
    /// true = запрос репоста в процессе.
    var repostInProgress: Bool = false
    /// Показывать меню поста с «Удалить» (свой пост). false или onDelete == nil — меню не показывается.
    var canDeletePost: Bool = false
    /// Тап «Удалить» в меню поста. nil = пункт не показывать.
    var onDelete: (() -> Void)? = nil
    /// true = запрос удаления в процессе (кнопку не нажимать).
    var deleteInProgress: Bool = false
    /// Показывать «Закрепить пост» / «Открепить» в меню (свой пост на своей стене).
    var canPinPost: Bool = false
    /// true = пост закреплён (показывать «Открепить»).
    var isPinned: Bool = false
    /// Тап «Закрепить пост». nil = пункт не показывать.
    var onPin: (() -> Void)? = nil
    /// Тап «Открепить». nil = пункт не показывать.
    var onUnpin: (() -> Void)? = nil
    /// true = запрос закрепления/открепления в процессе.
    var pinInProgress: Bool = false
    /// Удалить фото в fullscreen галерее (свои фото). (token, ownerId, photoId) → true при успехе. nil = пункт не показывать.
    var onDeletePhoto: ((String, Int, Int) async -> Bool)? = nil
    /// Сделать фото главным в профиле (photos.makeCover). Возвращает (успех, сообщение об ошибке). nil = пункт не показывать.
    var onMakeProfilePhoto: ((String, Int, Int) async -> (Bool, String?))? = nil
    /// После успешного репоста из fullscreen галереи — обновить счётчик в ленте (новый reposts_count).
    var onRepostSuccessFromGallery: ((Int) -> Void)? = nil

    @Environment(\.makeProfilePhotoForGallery) private var makeProfilePhotoFromEnvironment
    @State private var isTextExpanded = false
    @State private var fullScreenPhotoIndex: Int? = nil
    /// Индекс фото из репоста для fullscreen-галереи (отдельный state — открывается своим fullScreenCover).
    @State private var repostFullScreenPhotoIndex: Int? = nil
    /// Токен, захваченный при открытии галереи (в fullScreenCover getAccessToken часто пуст — сохраняем при тапе).
    @State private var tokenForGallery: String = ""
    /// URL для открытия во встроенном браузере (SFSafariViewController).
    @State private var safariURL: URL? = nil
    private let textLineLimitCollapsed = 3

    /// Превью URL + gallery-индекс для каждого photo-вложения.
    /// thumbnailURL = nil → показываем placeholder. galleryIndex = nil → тап не открывает галерею.
    private struct PhotoGridItem {
        let thumbnailURL: String?
        let galleryIndex: Int?
    }

    private var photoGridItems: [PhotoGridItem] {
        guard let attachments = post.attachments else { return [] }
        var galleryIdx = 0
        return attachments.compactMap { att -> PhotoGridItem? in
            guard let photo = att.photo else { return nil }
            let thumbURL = photo.feedPreviewURL ?? photo.displayURL ?? photo.thumbnailDisplayURL
            let dispURL  = photo.displayURL ?? photo.feedPreviewURL
            let gIdx: Int? = dispURL != nil ? galleryIdx : nil
            if dispURL != nil { galleryIdx += 1 }
            return PhotoGridItem(thumbnailURL: thumbURL, galleryIndex: gIdx)
        }
    }

    /// URL фото для полноэкранного просмотра (крупные размеры) — только реальные URL, без nil.
    private var photoDisplayURLs: [String] {
        guard let attachments = post.attachments else { return [] }
        return attachments.compactMap { $0.photo?.displayURL ?? $0.photo?.feedPreviewURL }
    }

    // Используется в fullScreenGalleryView
    private var photoThumbnailURLs: [String] {
        photoGridItems.compactMap { $0.thumbnailURL }
    }

    private var photoThumbnailURLsAsURLs: [URL] { photoThumbnailURLs.compactMap { URL(string: $0) } }
    private var photoDisplayURLsAsURLs: [URL] { photoDisplayURLs.compactMap { URL(string: $0) } }

    /// Идентификаторы для «Добавить в сохранённые» — в том же порядке, что и photoDisplayURLs.
    private var photoIdsForSavingFromPost: [PhotoSaveId] {
        let owner = post.ownerId ?? post.fromId ?? 0
        return (post.attachments ?? []).compactMap { att -> PhotoSaveId? in
            guard let p = att.photo else { return nil }
            return PhotoSaveId(ownerId: owner, photoId: p.id, accessKey: p.accessKey)
        }
    }

    /// VK API для «Добавить в сохранённые» в fullscreen галерее — галерея сама вызывает photosCopy.
    var vkApi: VKApiService? = nil
    /// Опционально: возврат токена для «Удалить» / «Сделать фото профиля».
    var getAccessToken: (() -> String)? = nil

    /// Видео из вложений поста с ownerId для плеера/video.get.
    private var videoAttachments: [(video: VKVideo, ownerId: Int)] {
        let owner = post.ownerId ?? post.fromId ?? 0
        return (post.attachments ?? [])
            .compactMap { att -> (VKVideo, Int)? in
                guard let v = att.video else { return nil }
                return (v, owner)
            }
    }

    private var linkAttachments: [VKLink] {
        (post.attachments ?? []).compactMap { $0.link }
    }

    private var pollAttachments: [VKPoll] {
        (post.attachments ?? []).compactMap { $0.poll }
    }

    /// Есть вложения, которые не фото/видео/ссылка/опрос — показываем плейсхолдер (doc и т.д.).
    private var hasOtherMedia: Bool {
        guard let attachments = post.attachments else { return false }
        return attachments.contains { att in
            att.photo == nil && att.video == nil && att.link == nil && att.poll == nil && att.doc != nil
        }
    }

    var body: some View {
        postBodyContent
            .fullScreenCover(isPresented: Binding(
                get: { fullScreenPhotoIndex != nil },
                set: { if !$0 { fullScreenPhotoIndex = nil } }
            )) {
                fullScreenGalleryContent
            }
            .fullScreenCover(isPresented: Binding(
                get: { repostFullScreenPhotoIndex != nil },
                set: { if !$0 { repostFullScreenPhotoIndex = nil } }
            )) {
                repostFullScreenGalleryContent
            }
            .sheet(isPresented: Binding(
                get: { safariURL != nil },
                set: { if !$0 { safariURL = nil } }
            )) {
                if let url = safariURL {
                    SafariView(url: url).ignoresSafeArea()
                }
            }
    }

    private var postBodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 10)
            if !post.text.isEmpty {
                bodyText
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            if !photoGridItems.isEmpty {
                photoGridView
            }
            if !videoAttachments.isEmpty {
                videoRow
            }
            if !linkAttachments.isEmpty {
                linkRow
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if !pollAttachments.isEmpty {
                pollRow
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if hasOtherMedia {
                mediaPlaceholder
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if let repost = post.copyHistory?.first {
                repostBlock(repost)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if displayLikesCount > 0 || onLike != nil || post.commentsCount > 0 || onTapComments != nil || displayRepostsCount > 0 || onRepostToWall != nil {
                likesCommentsRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(VKTheme.Colors.background)
        .overlay(
            Rectangle()
                .strokeBorder(VKTheme.Colors.separator, lineWidth: VKTheme.Border.card)
        )
    }

    @ViewBuilder
    private var fullScreenGalleryContent: some View {
        if let idx = fullScreenPhotoIndex, !photoDisplayURLsAsURLs.isEmpty {
            AnyView(fullScreenGalleryView(initialIndex: idx))
        }
    }

    @ViewBuilder
    private var repostFullScreenGalleryContent: some View {
        if let idx = repostFullScreenPhotoIndex,
           let repost = post.copyHistory?.first {
            let urls = (repost.attachments ?? [])
                .compactMap { $0.photo?.displayURL }
                .compactMap { URL(string: $0) }
            if !urls.isEmpty {
                FullScreenPhotoGalleryView(
                    urls: urls,
                    initialIndex: min(idx, urls.count - 1),
                    onDismiss: { repostFullScreenPhotoIndex = nil }
                )
            }
        }
    }

    private func fullScreenGalleryView(initialIndex idx: Int) -> FullScreenPhotoGalleryView {
        let ownerId = post.ownerId ?? post.fromId ?? 0
        let onLikeAction: (() -> Void)? = likeInProgress ? nil : onLike
        let postContext: PostCommentsContext? = (onTapComments != nil && authService != nil)
            ? PostCommentsContext(ownerId: ownerId, postId: post.id, totalCount: post.commentsCount)
            : nil
        let apiForSaved: VKApiService? = canDeletePost ? nil : vkApi
        let deletePhoto: ((String, Int, Int) async -> Bool)? = canDeletePost
            ? onDeletePhoto
            : nil as ((String, Int, Int) async -> Bool)?
        let photoIds: [PhotoSaveId]? = photoIdsForSavingFromPost.isEmpty ? nil : photoIdsForSavingFromPost
        let makeProfile: ((String, Int, Int) async -> (Bool, String?))? = canDeletePost ? (onMakeProfilePhoto ?? makeProfilePhotoFromEnvironment) : nil as ((String, Int, Int) async -> (Bool, String?))?
        let repostObject = "wall\(ownerId)_\(post.id)"
        let gallery: FullScreenPhotoGalleryView = FullScreenPhotoGalleryView(
            urls: photoDisplayURLsAsURLs,
            initialIndex: min(idx, photoDisplayURLsAsURLs.count - 1),
            onDismiss: { fullScreenPhotoIndex = nil },
            likesCount: displayLikesCount,
            commentsCount: post.commentsCount,
            repostsCount: repostsCountOverride ?? post.repostsCount,
            isLiked: displayIsLiked,
            onLike: onLikeAction,
            onTapComments: onTapComments,
            postCommentsContext: postContext,
            authService: authService,
            photoIdsForSaving: photoIds,
            vkApi: apiForSaved,
            getAccessToken: getAccessToken,
            initialAccessToken: tokenForGallery.isEmpty ? (getAccessToken?() ?? "") : tokenForGallery,
            isOwnPhotos: canDeletePost,
            onDeletePhoto: deletePhoto,
            isProfileAlbum: canDeletePost,
            onMakeProfilePhoto: makeProfile,
            repostObject: repostObject,
            onRepostSuccess: onRepostSuccessFromGallery
        )
        return gallery
    }

    // MARK: - Header (тап → группа или профиль, если передан feedDestination)

    /// Одна строка даты: календарная при наличии, иначе относительная (без дублирования).
    private var displayDateString: String {
        if let cal = calendarDate, !cal.isEmpty { return cal }
        return relativeDate
    }

    private var headerContent: some View {
        HStack(alignment: .center, spacing: 10) {
            avatarView
            Text(authorName)
                .font(VKTheme.TextStyle.postAuthorName)
                .foregroundColor(VKTheme.Colors.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(displayDateString)
                .font(VKTheme.TextStyle.timestamp)
                .foregroundColor(VKTheme.Colors.textSecondary)
            if (canDeletePost && onDelete != nil) || (canPinPost && (onPin != nil || onUnpin != nil)) {
                Menu {
                    if canPinPost, isPinned, let unpin = onUnpin {
                        Button(action: unpin) {
                            Label("Открепить", systemImage: "pin.slash")
                        }
                        .disabled(pinInProgress)
                    } else if canPinPost, !isPinned, let pin = onPin {
                        Button(action: pin) {
                            Label("Закрепить пост", systemImage: "pin")
                        }
                        .disabled(pinInProgress)
                    }
                    if canDeletePost, onDelete != nil {
                        Button(role: .destructive, action: { onDelete?() }) {
                            Label("Удалить", systemImage: "trash")
                        }
                        .disabled(deleteInProgress)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15))
                        .foregroundColor(VKTheme.Colors.textSecondary)
                        .symbolRenderingMode(.monochrome)
                }
                .disabled(deleteInProgress || pinInProgress)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let dest = feedDestination {
            NavigationLink(value: dest) { headerContent }
        } else {
            headerContent
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        let size = VKTheme.AvatarSize.post
        let shape = RoundedRectangle(cornerRadius: VKTheme.Radius.avatarSquare)
        if let urlString = authorAvatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(VKTheme.Colors.secondaryBackground)
                        .overlay(Image(systemName: "person").foregroundColor(VKTheme.Colors.textSecondary))
                case .empty:
                    Rectangle()
                        .fill(VKTheme.Colors.secondaryBackground)
                        .overlay(ProgressView())
                @unknown default:
                    Rectangle()
                        .fill(VKTheme.Colors.secondaryBackground)
                }
            }
            .frame(width: size, height: size)
            .clipShape(shape)
        } else {
            Rectangle()
                .fill(VKTheme.Colors.secondaryBackground)
                .overlay(Image(systemName: "person").foregroundColor(VKTheme.Colors.textSecondary))
                .frame(width: size, height: size)
                .clipShape(shape)
        }
    }

    // MARK: - Body text

    private var bodyText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.text)
                .font(VKTheme.TextStyle.postBody)
                .foregroundColor(VKTheme.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(isTextExpanded ? nil : textLineLimitCollapsed)
                .frame(maxWidth: .infinity, alignment: .leading)

            if post.text.count > 100 {
                Button(isTextExpanded ? "Свернуть" : "Показать ещё") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTextExpanded.toggle()
                    }
                }
                .font(VKTheme.TextStyle.timestamp)
                .foregroundColor(VKTheme.Colors.primary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Media

    /// Максимальная высота одного фото в ленте (scaledToFit — не обрезает портретные).
    private let singlePhotoMaxHeight: CGFloat = 520
    /// Высота ячейки в многофото-сетке.
    private let gridCellHeight: CGFloat = 120

    // MARK: Пазл-раскладка фото
    // 1 → полная ширина; 2 → 2 в ряд; 3 → 1+2; 4 → 2+2; 5 → 2+3; 6 → 3+3; 7 → 1+3+3; 8 → 2+3+3; 9 → 3+3+3; 10+ → 3+3+3 + счётчик.

    @ViewBuilder
    private var photoGridView: some View {
        let all   = photoGridItems
        let total = all.count
        let shown = min(total, 9)
        let extra = total - shown
        let items = Array(all.prefix(shown))
        let h     = gridCellHeight

        VStack(spacing: 4) {
            switch shown {
            case 1:
                singlePhotoCell(items[0])
            case 2:
                row2(items[0], items[1], h: h, extra2: extra)
            case 3:
                gridCell(items[0], height: h, extra: 0)
                row2(items[1], items[2], h: h, extra2: extra)
            case 4:
                row2(items[0], items[1], h: h, extra2: 0)
                row2(items[2], items[3], h: h, extra2: extra)
            case 5:
                row2(items[0], items[1], h: h, extra2: 0)
                row3(items[2], items[3], items[4], h: h, extra3: extra)
            case 6:
                row3(items[0], items[1], items[2], h: h, extra3: 0)
                row3(items[3], items[4], items[5], h: h, extra3: extra)
            case 7:
                gridCell(items[0], height: h, extra: 0)
                row3(items[1], items[2], items[3], h: h, extra3: 0)
                row3(items[4], items[5], items[6], h: h, extra3: extra)
            case 8:
                row2(items[0], items[1], h: h, extra2: 0)
                row3(items[2], items[3], items[4], h: h, extra3: 0)
                row3(items[5], items[6], items[7], h: h, extra3: extra)
            default: // 9
                row3(items[0], items[1], items[2], h: h, extra3: 0)
                row3(items[3], items[4], items[5], h: h, extra3: 0)
                row3(items[6], items[7], items[8], h: h, extra3: extra)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row2(_ a: PhotoGridItem, _ b: PhotoGridItem, h: CGFloat, extra2: Int) -> some View {
        HStack(spacing: 4) {
            gridCell(a, height: h, extra: 0)
            gridCell(b, height: h, extra: extra2)
        }
        .frame(maxWidth: .infinity)
    }

    private func row3(_ a: PhotoGridItem, _ b: PhotoGridItem, _ c: PhotoGridItem, h: CGFloat, extra3: Int) -> some View {
        HStack(spacing: 4) {
            gridCell(a, height: h, extra: 0)
            gridCell(b, height: h, extra: 0)
            gridCell(c, height: h, extra: extra3)
        }
        .frame(maxWidth: .infinity)
    }

    /// Одиночное фото в посте: scaledToFit без обрезки, высота по содержимому (max singlePhotoMaxHeight).
    @ViewBuilder
    private func singlePhotoCell(_ item: PhotoGridItem) -> some View {
        ZStack {
            if let urlString = item.thumbnailURL,
               let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Color(.systemGray5)
                            .frame(height: 200)
                            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    case .empty:
                        Color(.systemGray6)
                            .frame(height: 200)
                            .overlay { ProgressView() }
                    @unknown default:
                        Color(.systemGray6).frame(height: 200)
                    }
                }
                .id(urlString)
            } else {
                Color(.systemGray5)
                    .frame(height: 200)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: singlePhotoMaxHeight)
        .onTapGesture {
            guard let idx = item.galleryIndex else { return }
            tokenForGallery = getAccessToken?() ?? authService?.accessToken ?? ""
            fullScreenPhotoIndex = idx
        }
        .allowsHitTesting(item.galleryIndex != nil)
    }

    /// Одна ячейка сетки: фото или placeholder + опциональный счётчик «+N».
    @ViewBuilder
    private func gridCell(_ item: PhotoGridItem, height: CGFloat, extra: Int) -> some View {
        ZStack {
            if let urlString = item.thumbnailURL,
               let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Color(.systemGray5)
                            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    case .empty:
                        Color(.systemGray6).overlay { ProgressView() }
                    @unknown default:
                        Color(.systemGray6)
                    }
                }
                .id(urlString)
            } else {
                Color(.systemGray5)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }

            if extra > 0 {
                Color.black.opacity(0.45)
                Text("+\(extra)")
                    .font(.title2).fontWeight(.semibold).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .onTapGesture {
            guard let idx = item.galleryIndex else { return }
            tokenForGallery = getAccessToken?() ?? authService?.accessToken ?? ""
            fullScreenPhotoIndex = idx
        }
        .allowsHitTesting(item.galleryIndex != nil || extra == 0)
    }

    /// Строка видео: одно видео — на всю ширину 16:9; несколько — 2-column grid.
    @ViewBuilder
    private var videoRow: some View {
        let count = videoAttachments.count
        if count == 1, let pair = videoAttachments.first {
            videoCard(video: pair.video, ownerId: pair.ownerId, fullWidth: true)
        } else {
            let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(videoAttachments.enumerated()), id: \.offset) { _, pair in
                    videoCard(video: pair.video, ownerId: pair.ownerId, fullWidth: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private func videoCard(video: VKVideo, ownerId: Int, fullWidth: Bool) -> some View {
        let previewURL = video.previewImageURL
        let cardHeight: CGFloat = fullWidth
            ? (UIScreen.main.bounds.width * 9 / 16).rounded()
            : 120
        return Button {
            Task { await onTapVideo?(video, ownerId, post) }
        } label: {
            ZStack(alignment: .bottom) {
                // Превью
                Group {
                    if let urlString = previewURL, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                Color(.systemGray4)
                            }
                        }
                    } else {
                        Color(.systemGray4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Нижняя плашка: название + длительность
                HStack(spacing: 4) {
                    if let title = video.title, !title.isEmpty {
                        Text(title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let sec = video.duration {
                        Text(formatDuration(sec))
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(3)
                    }
                }
                .padding(8)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Кнопка play по центру
                Image(systemName: "play.circle.fill")
                    .font(.system(size: fullWidth ? 52 : 36))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: cardHeight)
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .buttonStyle(.plain)
        .disabled(onTapVideo == nil)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 {
            return String(format: "%d:%02d", m, s)
        }
        return "0:\(String(format: "%02d", s))"
    }

    /// Ссылки: заголовок/URL, тап → Safari.
    private var linkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(linkAttachments.enumerated()), id: \.offset) { _, link in
                if let url = URL(string: link.url) {
                    Button {
                        safariURL = url
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                if let t = link.title, !t.isEmpty {
                                    Text(t)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                }
                                Text(link.url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(10)
                        .background(VKTheme.Colors.secondaryBackground)
                        .overlay(Rectangle().strokeBorder(VKTheme.Colors.separator, lineWidth: VKTheme.Border.card))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pollVoteKey(_ poll: VKPoll) -> String {
        let owner = post.ownerId ?? post.fromId ?? 0
        return "\(owner)_\(post.id)_\(poll.id)"
    }

    /// Опросы: вопрос, варианты; при onPollVote — тап по варианту отправляет голос; после голоса — выбор и счётчики из override.
    private var pollRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(pollAttachments.enumerated()), id: \.offset) { _, poll in
                let key = pollVoteKey(poll)
                let override = pollVoteOverrides?[key]
                let inProgress = pollVoteInProgress.contains(key)
                let canVote = onPollVote != nil && (poll.closed != true) && override == nil && !inProgress

                VStack(alignment: .leading, spacing: 6) {
                    if let q = poll.question, !q.isEmpty {
                        Text(q)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    if let answers = poll.answers, !answers.isEmpty {
                        let totalVotes = override?.totalVotes ?? poll.votes ?? 0
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(answers, id: \.id) { a in
                                let voteCount = override?.answerVotes[a.id] ?? a.votes ?? 0
                                let isSelected = override?.selectedAnswerId == a.id
                                let ratePercent: Int? = totalVotes > 0 ? Int((Double(voteCount) / Double(totalVotes)) * 100) : nil
                                HStack(spacing: 8) {
                                    Text(a.text ?? "")
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                    if let pct = ratePercent {
                                        Text("\(pct)%")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Text("\(voteCount)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isSelected ? VKTheme.Colors.primary.opacity(0.12) : VKTheme.Colors.secondaryBackground)
                                .overlay(Rectangle().strokeBorder(isSelected ? VKTheme.Colors.primary.opacity(0.3) : VKTheme.Colors.separator, lineWidth: VKTheme.Border.card))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard canVote else { return }
                                    onPollVote?(post, poll, a.id)
                                }
                                .disabled(!canVote)
                            }
                        }
                    }
                    if let votes = override?.totalVotes ?? poll.votes {
                        Text("Всего голосов: \(votes)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if inProgress {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VKTheme.Colors.secondaryBackground)
                .overlay(Rectangle().strokeBorder(VKTheme.Colors.separator, lineWidth: VKTheme.Border.card))
            }
        }
    }

    private var mediaPlaceholder: some View {
        HStack {
            Image(systemName: "doc")
                .foregroundColor(VKTheme.Colors.textSecondary)
            Text("Документ")
                .font(VKTheme.TextStyle.timestamp)
                .foregroundColor(VKTheme.Colors.textSecondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VKTheme.Colors.secondaryBackground)
        .overlay(Rectangle().strokeBorder(VKTheme.Colors.separator, lineWidth: VKTheme.Border.card))
    }

    /// Блок репоста: автор, текст и превью фото из первого элемента copy_history.
    @ViewBuilder
    private func repostBlock(_ repost: VKPost) -> some View {
        let repostAuthorName = VKaif.authorName(for: repost, profiles: profiles, groups: groups)
        let repostAvatarURL = VKaif.authorAvatarURL(for: repost, profiles: profiles, groups: groups)
        let repostPhotoURLs = (repost.attachments ?? []).compactMap { $0.photo?.feedPreviewURL ?? $0.photo?.displayURL }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let urlString = repostAvatarURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default:
                            Rectangle()
                                .fill(VKTheme.Colors.secondaryBackground)
                                .overlay(Image(systemName: "person").foregroundStyle(VKTheme.Colors.textSecondary))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: VKTheme.Radius.avatarSquare))
                } else {
                    Rectangle()
                        .fill(VKTheme.Colors.secondaryBackground)
                        .overlay(Image(systemName: "person").foregroundStyle(VKTheme.Colors.textSecondary))
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: VKTheme.Radius.avatarSquare))
                }
                Text(repostAuthorName)
                    .font(VKTheme.TextStyle.timestamp)
                    .fontWeight(.semibold)
                    .foregroundColor(VKTheme.Colors.primary)
                Spacer(minLength: 0)
            }
            if !repost.text.isEmpty {
                Text(repost.text)
                    .font(VKTheme.TextStyle.postBody)
                    .foregroundColor(VKTheme.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !repostPhotoURLs.isEmpty {
                let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(repostPhotoURLs.prefix(6).enumerated()), id: \.offset) { index, urlString in
                        let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
                        ZStack {
                            if let url {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image): image.resizable().scaledToFill()
                                    case .failure:
                                        Color(VKTheme.Colors.secondaryBackground)
                                            .overlay { Image(systemName: "photo").foregroundStyle(VKTheme.Colors.textSecondary) }
                                    case .empty:
                                        Color(VKTheme.Colors.secondaryBackground).overlay { ProgressView() }
                                    @unknown default: Color(VKTheme.Colors.secondaryBackground)
                                    }
                                }
                                .id(urlString)
                            } else {
                                Color(VKTheme.Colors.secondaryBackground)
                                    .overlay { Image(systemName: "photo").foregroundStyle(VKTheme.Colors.textSecondary) }
                            }
                        }
                        .frame(height: 80)
                        .clipped()
                        .onTapGesture {
                            repostFullScreenPhotoIndex = index
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VKTheme.Colors.secondaryBackground)
        .overlay(Rectangle().strokeBorder(VKTheme.Colors.separator, lineWidth: VKTheme.Border.card))
    }

    // MARK: - Лайки / комментарии (счётчики)

    private var displayLikesCount: Int {
        likesCountOverride ?? post.likesCount
    }

    private var displayIsLiked: Bool {
        isLikedOverride ?? (post.likes?.userLikes == 1)
    }

    private var displayRepostsCount: Int {
        repostsCountOverride ?? post.repostsCount
    }

    private var likesCommentsRow: some View {
        HStack(spacing: 16) {
            if displayLikesCount > 0 || onLike != nil {
                if let action = onLike {
                    Button(action: action) {
                        Label(
                            "\(displayLikesCount)",
                            systemImage: displayIsLiked ? "heart.fill" : "heart"
                        )
                        .font(VKTheme.TextStyle.timestamp)
                        .foregroundColor(displayIsLiked ? .red : VKTheme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(likeInProgress)
                } else {
                    Label("\(displayLikesCount)", systemImage: "heart.fill")
                        .font(VKTheme.TextStyle.timestamp)
                        .foregroundColor(VKTheme.Colors.textSecondary)
                }
            }
            if onTapComments != nil {
                Button(action: { onTapComments?() }) {
                    Label("\(post.commentsCount)", systemImage: "bubble.right")
                        .font(VKTheme.TextStyle.timestamp)
                        .foregroundColor(VKTheme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            } else if post.commentsCount > 0 {
                Label("\(post.commentsCount)", systemImage: "bubble.right")
                    .font(VKTheme.TextStyle.timestamp)
                    .foregroundColor(VKTheme.Colors.textSecondary)
            }
            if displayRepostsCount > 0 || onRepostToWall != nil {
                if let toWall = onRepostToWall {
                    Menu {
                        Button(action: toWall) {
                            Label("На свою стену", systemImage: "square.and.arrow.up")
                        }
                        .disabled(repostInProgress)
                        if onRepostToDM != nil {
                            Button(action: { onRepostToDM?() }) {
                                Label("В личку", systemImage: "paperplane")
                            }
                        }
                    } label: {
                        Label("\(displayRepostsCount)", systemImage: "arrowshape.turn.up.right")
                            .font(VKTheme.TextStyle.timestamp)
                            .foregroundColor(VKTheme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(repostInProgress)
                } else {
                    Label("\(displayRepostsCount)", systemImage: "arrowshape.turn.up.right")
                        .font(VKTheme.TextStyle.timestamp)
                        .foregroundColor(VKTheme.Colors.textSecondary)
                }
            }
        }
    }
}

// MARK: - Helpers

/// Относительная дата: "2 ч назад", "вчера", "15 янв".
func relativeDateString(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

/// Календарная дата поста с временем:
/// - сегодня → "14:32"
/// - текущий год → "3 апр в 14:32"
/// - другой год → "15 янв 2025 в 14:32"
func calendarDateString(from date: Date) -> String {
    let cal = Calendar.current
    let now = Date()
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")

    let timeStr: String = {
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }()

    if cal.isDateInToday(date) {
        return timeStr
    }

    if cal.component(.year, from: date) == cal.component(.year, from: now) {
        f.dateFormat = "d MMM"
        return "\(f.string(from: date)) в \(timeStr)"
    }

    f.dateFormat = "d MMM yyyy"
    return "\(f.string(from: date)) в \(timeStr)"
}

/// Имя автора поста: из profiles (положительный fromId) или groups (отрицательный ownerId).
func authorName(for post: VKPost, profiles: [VKProfile], groups: [VKGroup]) -> String {
    let fromId = post.fromId ?? post.ownerId ?? 0
    if fromId > 0 {
        if let p = profiles.first(where: { $0.id == fromId }) {
            return [p.firstName, p.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
    } else {
        let groupId = abs(fromId)
        if let g = groups.first(where: { $0.id == groupId }) {
            return g.name ?? "Группа"
        }
    }
    return "Автор"
}

/// URL аватара 50x50 для автора поста.
func authorAvatarURL(for post: VKPost, profiles: [VKProfile], groups: [VKGroup]) -> String? {
    let fromId = post.fromId ?? post.ownerId ?? 0
    if fromId > 0 {
        return profiles.first(where: { $0.id == fromId })?.photo50
    } else {
        let groupId = abs(fromId)
        return groups.first(where: { $0.id == groupId })?.photo50
    }
}

#Preview {
    let post = VKPost(
        id: 1,
        fromId: 1,
        ownerId: 1,
        date: Date(),
        text: "Пример текста поста. Он может быть длинным и тогда появится кнопка «Показать ещё», чтобы развернуть весь текст и прочитать его полностью.",
        markedAsAds: nil,
        postType: nil,
        sourceType: nil,
        attachments: nil,
        copyHistory: nil
    )
    return PostCellView(
        post: post,
        authorName: "Иван Иванов",
        authorAvatarURL: nil,
        relativeDate: "2 ч назад"
    )
    .padding()
}

// Инициализатор для превью (VKPost из Decoder только)
extension VKPost {
    init(id: Int, fromId: Int?, ownerId: Int?, date: Date, text: String, markedAsAds: Int?, postType: String?, sourceType: String?, attachments: [VKAttachment]?, copyHistory: [VKPost]?, likes: VKPostLikes? = nil, comments: VKPostComments? = nil, reposts: VKPostReposts? = nil, isPinned: Int? = nil) {
        self.id = id
        self.fromId = fromId
        self.ownerId = ownerId
        self.date = date
        self.text = text
        self.markedAsAds = markedAsAds
        self.postType = postType
        self.sourceType = sourceType
        self.attachments = attachments
        self.copyHistory = copyHistory
        self.likes = likes
        self.comments = comments
        self.reposts = reposts
        self.isPinned = isPinned
    }
}
