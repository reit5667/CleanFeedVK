import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ProfileView: View {

    @ObservedObject var authService: AuthService
    @ObservedObject var viewModel: ProfileViewModel
    private var userId: Int? { viewModel.userId }
    private var isOwnProfile: Bool { userId == nil }

    @State private var isAvatarFullScreenPresented = false
    @State private var isAvatarActionSheetPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var avatarUploadInProgress = false
    @State private var avatarUploadMessage: String? = nil
    @State private var avatarUploadSuccess = false

    @State private var showFriends = false
    @State private var showPhotos = false
    @State private var showGroups = false
    @State private var showInfo = false

    private let vkApi = VKApiService()

    var body: some View {
        Group {
            switch viewModel.userLoadState {
            case .idle, .loading:
                ProgressView("Загрузка профиля…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if let u = viewModel.user {
                    profileContent(user: u)
                } else {
                    ContentUnavailableView("Профиль не найден", systemImage: "person.slash")
                }
            case .failed(let error):
                ContentUnavailableView(
                    "Ошибка",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(error.localizedDescription)
                )
            case .notAuthenticated:
                ContentUnavailableView(
                    "Войдите в аккаунт",
                    systemImage: "person.badge.key",
                    description: Text("Профиль доступен после авторизации")
                )
            }
        }
        .navigationTitle(viewModel.user?.displayName ?? "Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .vkBlueNavBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .loaded = viewModel.userLoadState {
                    Button { viewModel.refreshAll() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear { viewModel.loadProfileIfNeeded() }
    }

    // MARK: - Основной контент

    private func profileContent(user: VKUserDetail) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                profileHeader(user: user)
                wallSection(user: user)
            }
        }
        .fullScreenCover(isPresented: $isAvatarFullScreenPresented) {
            profileMainPhotoGalleryView(user: user)
        }
        .navigationDestination(isPresented: $showFriends) {
            friendsScreen(user: user)
        }
        .navigationDestination(isPresented: $showPhotos) {
            photosScreen(user: user)
        }
        .navigationDestination(isPresented: $showGroups) {
            groupsScreen(user: user)
        }
    }

    // MARK: - Шапка профиля

    private func profileHeader(user: VKUserDetail) -> some View {
        VStack(spacing: 0) {
            avatarSection(user: user)

            VStack(alignment: .leading, spacing: 6) {
                nameRow(user: user)
                onlineStatusRow(user: user)
                if let status = user.status, !status.isEmpty {
                    Text(status)
                        .font(VKTheme.TextStyle.commentBody)
                        .foregroundStyle(VKTheme.Colors.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if showInfo {
                inlineInfoBlock(user: user)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VKTheme.Colors.secondaryBackground)
                    .transition(.opacity)
            }

            actionButtonsRow(user: user)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            statsBlock(user: user)
                .padding(.top, 16)

            if !viewModel.profilePhotos.isEmpty {
                photoStrip(photos: viewModel.profilePhotos)
                    .padding(.top, 2)
            }

            wallTabLabel
                .padding(.top, 8)
        }
        .background(Color.white)
    }

    // MARK: - Аватар

    private func avatarSection(user: VKUserDetail) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    Group {
                        if let urlString = mainPhotoURL(user: user), let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                case .failure:
                                    Image(systemName: "person.crop.square.fill")
                                        .resizable().scaledToFit()
                                        .foregroundStyle(.secondary)
                                        .padding(54)
                                        .background(Color(.systemGray5))
                                case .empty:
                                    Color(.systemGray5).overlay(ProgressView())
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        } else {
                            Image(systemName: "person.crop.square.fill")
                                .resizable().scaledToFit()
                                .foregroundStyle(.secondary)
                                .padding(54)
                                .background(Color(.systemGray5))
                        }
                    }
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: VKTheme.Radius.avatarSquare))
            .onTapGesture {
                if isOwnProfile {
                    isAvatarActionSheetPresented = true
                } else {
                    isAvatarFullScreenPresented = true
                }
            }
            .confirmationDialog("Фото профиля", isPresented: $isAvatarActionSheetPresented, titleVisibility: .visible) {
                Button("Открыть фото") { isAvatarFullScreenPresented = true }
                PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                    Text(avatarUploadInProgress ? "Загрузка…" : "Изменить аватарку")
                }
                .disabled(avatarUploadInProgress)
                Button("Отмена", role: .cancel) { }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let item = newItem else { return }
                Task { await uploadProfilePhoto(from: item) }
            }

            if avatarUploadInProgress {
                ProgressView()
                    .tint(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
                    .offset(x: 4, y: 4)
            }
        }
    }

    // MARK: - Имя + галочка + стрелка

    private func nameRow(user: VKUserDetail) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { showInfo.toggle() } } label: {
            HStack(spacing: 6) {
                Text(user.displayName)
                    .font(VKTheme.TextStyle.profileName)
                    .foregroundStyle(VKTheme.Colors.textPrimary)
                if user.verified == 1 {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(VKTheme.Colors.primary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VKTheme.Colors.textSecondary)
                    .rotationEffect(.degrees(showInfo ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - Инлайн блок подробной информации

    private func inlineInfoBlock(user: VKUserDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let bdate = formattedBdate(user.bdate) {
                infoRow(label: "День рождения", value: bdate)
            }
            if let hometown = user.homeTown, !hometown.isEmpty {
                infoRow(label: "Родной город", value: hometown)
            } else if let city = user.city?.title {
                infoRow(label: "Город", value: city)
            }
            if let country = user.country?.title {
                infoRow(label: "Страна", value: country)
            }
            if let rel = user.relationText {
                infoRow(label: "Семейное положение", value: rel)
            }
            if let site = user.site, !site.isEmpty {
                infoRow(label: "Сайт", value: site)
            }
            if let about = user.about, !about.isEmpty {
                infoRow(label: "О себе", value: about)
            }
            if let relatives = user.relatives, !relatives.isEmpty {
                infoRow(label: "Родственники", value: relatives.compactMap { $0.name }.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(VKTheme.TextStyle.commentTimestamp)
                .foregroundStyle(VKTheme.Colors.textSecondary)
            Text(value)
                .font(VKTheme.TextStyle.commentBody)
                .foregroundStyle(VKTheme.Colors.textPrimary)
        }
    }

    private func formattedBdate(_ bdate: String?) -> String? {
        guard let bdate, !bdate.isEmpty else { return nil }
        let parts = bdate.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return bdate }
        let months = ["января","февраля","марта","апреля","мая","июня",
                      "июля","августа","сентября","октября","ноября","декабря"]
        let day = parts[0]
        let monthName = parts[1] >= 1 && parts[1] <= 12 ? months[parts[1] - 1] : "\(parts[1])"
        return parts.count >= 3 ? "\(day) \(monthName) \(parts[2])" : "\(day) \(monthName)"
    }

    // MARK: - Онлайн-статус

    @ViewBuilder
    private func onlineStatusRow(user: VKUserDetail) -> some View {
        if user.isOnline {
            HStack(spacing: 5) {
                Circle()
                    .fill(VKTheme.Colors.online)
                    .frame(width: 7, height: 7)
                Text("В сети")
                    .font(VKTheme.TextStyle.timestamp)
                    .foregroundStyle(VKTheme.Colors.online)
            }
        } else if let lastSeen = user.lastSeen, let time = lastSeen.time {
            let date = Date(timeIntervalSince1970: TimeInterval(time))
            let prefix = user.isFemale ? "Была в сети" : "Был в сети"
            Text("\(prefix) \(formattedLastSeen(date))")
                .font(VKTheme.TextStyle.timestamp)
                .foregroundStyle(VKTheme.Colors.textSecondary)
        }
    }

    private func formattedLastSeen(_ date: Date) -> String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        if cal.isDateInToday(date) {
            fmt.dateFormat = "HH:mm"
            return "сегодня в \(fmt.string(from: date))"
        } else if cal.isDateInYesterday(date) {
            fmt.dateFormat = "HH:mm"
            return "вчера в \(fmt.string(from: date))"
        } else {
            fmt.dateFormat = "d MMM"
            return fmt.string(from: date)
        }
    }

    // MARK: - Кнопки действий

    @ViewBuilder
    private func actionButtonsRow(user: VKUserDetail) -> some View {
        VStack(spacing: 6) {
            if isOwnProfile {
                Button { } label: {
                    Text("Редактировать")
                        .font(VKTheme.TextStyle.profileAction)
                        .foregroundStyle(VKTheme.Colors.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: VKTheme.Radius.button)
                                .stroke(VKTheme.Colors.separator, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    Button { } label: {
                        Text("Добавить в друзья")
                            .font(VKTheme.TextStyle.profileActionSecondary)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(VKTheme.Colors.primary)
                            .cornerRadius(VKTheme.Radius.button)
                    }
                    .buttonStyle(.plain)

                    Button { } label: {
                        Text("Сообщение")
                            .font(VKTheme.TextStyle.profileActionSecondary)
                            .foregroundStyle(VKTheme.Colors.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: VKTheme.Radius.button)
                                    .stroke(VKTheme.Colors.separator, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let msg = avatarUploadMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(avatarUploadSuccess ? .green : .red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Блок статистики

    private func statsBlock(user: VKUserDetail) -> some View {
        let items: [(Int?, String, (() -> Void)?)] = [
            (user.counters?.friends,                       "друзья",      { showFriends = true }),
            (user.followersCount ?? user.counters?.followers, "подписчики", nil),
            (user.counters?.photos,                        "фото",        { showPhotos = true }),
            (user.counters?.videos,                        "видео",       nil),
            (user.counters?.audios,                        "аудио",       nil),
            (user.counters?.groups,                        "группы",      { showGroups = true })
        ]

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                statCell(items[0])
                statSeparator
                statCell(items[1])
                statSeparator
                statCell(items[2])
            }
            Rectangle()
                .fill(VKTheme.Colors.separator)
                .frame(height: 1)
                .padding(.horizontal, 12)
            HStack(spacing: 0) {
                statCell(items[3])
                statSeparator
                statCell(items[4])
                statSeparator
                statCell(items[5])
            }
        }
        .background(Color.white)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(VKTheme.Colors.separator, lineWidth: 1)
        )
    }

    private var statSeparator: some View {
        Rectangle()
            .fill(VKTheme.Colors.separator)
            .frame(width: 1)
            .padding(.vertical, 8)
    }

    private func statCell(_ item: (Int?, String, (() -> Void)?)) -> some View {
        Button {
            item.2?()
        } label: {
            VStack(spacing: 3) {
                Text(item.0.map { formatStatCount($0) } ?? "—")
                    .font(VKTheme.TextStyle.statNumber)
                    .foregroundStyle(item.2 != nil ? VKTheme.Colors.primary : VKTheme.Colors.textPrimary)
                Text(item.1)
                    .font(VKTheme.TextStyle.statLabel)
                    .foregroundStyle(VKTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.2 == nil)
    }

    private func formatStatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Полоса фото

    private func photoStrip(photos: [VKPhoto]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(photos, id: \.id) { photo in
                    Group {
                        if let s = photo.displayURL, let url = URL(string: s) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFill()
                                default: Color(.systemGray5)
                                }
                            }
                        } else {
                            Color(.systemGray5)
                        }
                    }
                    .frame(width: 80, height: 80)
                    .clipped()
                }
            }
        }
        .frame(height: 80)
    }

    // MARK: - Таб "ВСЕ ЗАПИСИ" (одиночный, без переключения)

    private var wallTabLabel: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("ВСЕ ЗАПИСИ")
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
        }
        .background(Color.white)
    }

    // MARK: - Стена

    private func wallSection(user: VKUserDetail) -> some View {
        ProfileWallTabView(
            posts: viewModel.wallPosts,
            profiles: viewModel.wallProfiles,
            groups: viewModel.wallGroups,
            loadState: viewModel.wallLoadState,
            user: user,
            authService: authService,
            isOwnProfile: isOwnProfile,
            onDeletePost: { viewModel.removeWallPost($0) },
            onRefresh: { await viewModel.loadWall(ownerId: user.id, forceRefresh: true) },
            embeddedInScroll: true
        )
    }

    // MARK: - Экраны навигации из статблока

    private func friendsScreen(user: VKUserDetail) -> some View {
        FriendsTabView(authService: authService)
            .vkBlueNavBar()
    }

    private func photosScreen(user: VKUserDetail) -> some View {
        ProfilePhotoTabView(
            albums: viewModel.albums,
            loadState: viewModel.albumsLoadState,
            authService: authService,
            ownerId: user.id,
            isOwnProfile: isOwnProfile,
            onRefresh: { await viewModel.loadAlbums(ownerId: user.id, forceRefresh: true) }
        )
        .navigationTitle("Фотографии")
        .navigationBarTitleDisplayMode(.inline)
        .vkBlueNavBar()
    }

    private func groupsScreen(user: VKUserDetail) -> some View {
        ProfileGroupsTabView(
            groups: viewModel.groups,
            loadState: viewModel.groupsLoadState,
            authService: authService,
            onRefresh: { await viewModel.loadGroups(forceRefresh: true) },
            onLeaveSuccess: { Task { await viewModel.loadGroups(forceRefresh: true) } },
            embeddedInScroll: false
        )
        .navigationTitle("Сообщества")
        .navigationBarTitleDisplayMode(.inline)
        .vkBlueNavBar()
        .onAppear { Task { await viewModel.loadGroups(forceRefresh: false) } }
    }

    // MARK: - Fullscreen фото профиля

    private func mainPhotoURL(user: VKUserDetail) -> String? {
        viewModel.profileMainPhoto?.displayURL ?? user.fullScreenAvatarURL
    }

    @ViewBuilder
    private func profileMainPhotoGalleryView(user: VKUserDetail) -> some View {
        if let urlString = mainPhotoURL(user: user), let url = URL(string: urlString) {
            let photo = viewModel.profileMainPhoto
            let ownerId = user.id
            FullScreenPhotoGalleryView(
                urls: [url],
                initialIndex: 0,
                onDismiss: { isAvatarFullScreenPresented = false },
                likesCount: photo?.likes?.count,
                commentsCount: photo?.comments?.count,
                isLiked: photo?.likes?.userLikes == 1,
                onLike: nil,
                photoCommentsContext: photo.map { PhotoCommentsContext(ownerId: ownerId, photoId: $0.id) },
                authService: authService,
                photoIdsForSaving: photo.flatMap { p in
                    guard let oid = p.ownerId else { return nil }
                    return [PhotoSaveId(ownerId: oid, photoId: p.id, accessKey: p.accessKey)]
                },
                vkApi: vkApi,
                getAccessToken: { authService.accessToken ?? "" },
                isOwnPhotos: isOwnProfile,
                isProfileAlbum: isOwnProfile
            )
        }
    }

    private func uploadProfilePhoto(from item: PhotosPickerItem) async {
        guard let token = authService.accessToken else {
            await MainActor.run { avatarUploadMessage = "Нет доступа"; avatarUploadSuccess = false }
            return
        }
        await MainActor.run { avatarUploadInProgress = true; avatarUploadMessage = nil }
        defer { Task { @MainActor in avatarUploadInProgress = false } }
        do {
            guard let imageData = try await item.loadTransferable(type: ImageDataTransfer.self) else {
                await MainActor.run { avatarUploadMessage = "Не удалось загрузить фото"; avatarUploadSuccess = false }
                return
            }
            let jpegData = imageData.dataAsJpeg
            let uploadUrl = try await vkApi.getOwnerPhotoUploadServer(token: token)
            let (server, hash, photo) = try await vkApi.uploadOwnerPhotoToServer(uploadUrl: uploadUrl, imageData: jpegData)
            try await vkApi.saveOwnerPhoto(token: token, server: server, hash: hash, photo: photo)
            await MainActor.run {
                avatarUploadMessage = "Фото профиля обновлено"
                avatarUploadSuccess = true
                selectedPhotoItem = nil
                viewModel.refreshAll()
            }
        } catch {
            await MainActor.run {
                avatarUploadMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                avatarUploadSuccess = false
            }
        }
    }
}

// MARK: - ProfileLoadState

enum ProfileLoadState {
    case idle
    case loading
    case loaded
    case failed(Error)
    case notAuthenticated
}

// MARK: - Обёртка для профиля друга

struct ProfileViewWrapper: View {
    @ObservedObject var authService: AuthService
    let userId: Int?

    @StateObject private var viewModel: ProfileViewModel

    init(authService: AuthService, userId: Int?) {
        self.authService = authService
        self.userId = userId
        _viewModel = StateObject(wrappedValue: ProfileViewModel(authService: authService, userId: userId))
    }

    var body: some View {
        ProfileView(authService: authService, viewModel: viewModel)
    }
}

// MARK: - Transferable для загрузки фото из галереи

private struct ImageDataTransfer: Transferable {
    let data: Data
    var dataAsJpeg: Data {
        guard let ui = UIImage(data: data) else { return data }
        return ui.jpegData(compressionQuality: 0.9) ?? data
    }
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in ImageDataTransfer(data: data) }
    }
}

#Preview("Свой профиль") {
    NavigationStack {
        ProfileViewWrapper(authService: AuthService(), userId: nil)
    }
}
