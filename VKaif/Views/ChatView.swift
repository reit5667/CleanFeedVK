import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import QuickLook

/// Экран чата: история (getHistory), ввод и отправка (send), пагинация вверх.
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let title: String?
    @ObservedObject var authService: AuthService
    var initialOutRead: Int = 0

    // UI-only state (не нужно кэшировать между переходами)
    @State private var inputText: String = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var replyToMessage: VKMessage? = nil
    @State private var showMaterials = false
    @State private var showForwardStub = false
    @State private var showAttachMenu = false
    @State private var showPhotosPicker = false
    @State private var searchText: String = ""
    @State private var isSearchActive = false
    @State private var galleryPhotos: [VKPhoto] = []
    @State private var galleryIndex: Int = 0
    @State private var showGallery = false
    enum ScrollTarget: Equatable {
        case bottom(Int)
        case top(Int)
        case message(Int)
    }
    @State private var scrollTarget: ScrollTarget? = nil
    @State private var lastMessageId: Int? = nil
    @State private var highlightedMessageId: Int? = nil
    @State private var audioPlayer: AVPlayer? = nil
    @State private var playingAudioMsgId: Int? = nil
    @State private var audioProgress: Double = 0
    @State private var audioTimer: Timer? = nil
    @State private var videoPlayerRequest: VideoPlayerRequest? = nil
    @State private var loadingVideoId: String? = nil
    @State private var quickLookURL: URL? = nil
    @State private var loadingDocId: Int? = nil
    @State private var showStickerPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @FocusState private var inputFocused: Bool
    @State private var showMembersSheet = false
    @State private var membersData: ConversationMembersResponse? = nil
    @State private var membersLoading = false
    @State private var pendingDeleteMsg: VKMessage? = nil
    @State private var showDeleteDialog = false

    private let vkApi = VKApiService()

    private var peerId: Int { viewModel.peerId }

    private var chatAvatarURL: URL? {
        if peerId > 0 && peerId < 2_000_000_000 {
            return viewModel.profiles.first(where: { $0.id == peerId })?.photo50.flatMap { URL(string: $0) }
        } else if peerId < 0 {
            return viewModel.groups.first(where: { -$0.id == peerId })?.photo50.flatMap { URL(string: $0) }
        }
        return nil
    }

    @ViewBuilder
    private func incomingAvatar(fromId: Int) -> some View {
        let url: URL? = {
            if fromId > 0 {
                return viewModel.profiles.first(where: { $0.id == fromId })?.photo50.flatMap { URL(string: $0) }
            } else if fromId < 0 {
                return viewModel.groups.first(where: { $0.id == abs(fromId) })?.photo50.flatMap { URL(string: $0) }
            }
            return chatAvatarURL
        }()
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Color(.systemGray4)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Color(.systemGray4)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var chatTitle: String {
        if let t = title, !t.isEmpty { return t }
        if peerId >= 200_000_0000 { return "Беседа" }
        if let p = viewModel.profiles.first(where: { $0.id == peerId }) {
            let name = [p.firstName, p.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? "ID\(p.id)" : name
        }
        if let g = viewModel.groups.first(where: { -$0.id == peerId }) { return g.name ?? "ID\(peerId)" }
        return "Загрузка…"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pinned = viewModel.pinnedMessage {
                pinnedBanner(pinned)
            }
            if isSearchActive {
                searchBar
            }
            if let err = sendError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            messagesList
            if let reply = replyToMessage {
                replyBanner(reply)
            }
            if !isSearchActive {
                inputBar
            }
        }
        .background(VKTheme.Colors.chatBackground.ignoresSafeArea())
        .navigationTitle(chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        .vkBlueNavBar()
        .toolbar {
            ToolbarItem(placement: .principal) {
                let titleContent = HStack(spacing: 8) {
                    if let url = chatAvatarURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: Image(systemName: "person.circle.fill").resizable().foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    }
                    Text(chatTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                if peerId >= 2_000_000_000 {
                    Button { loadAndShowMembers() } label: { titleContent }
                        .buttonStyle(.plain)
                } else {
                    titleContent
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        withAnimation { isSearchActive.toggle() }
                        if !isSearchActive { searchText = "" }
                    } label: {
                        Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                            .foregroundColor(.white)
                    }
                    Button {
                        showMaterials = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .onAppear {
            guard let token = authService.accessToken else { return }
            if viewModel.outRead == 0 && initialOutRead > 0 {
                viewModel.outRead = initialOutRead
            }
            viewModel.loadHistory(token: token)
            inputFocused = false
        }
        .refreshable {
            guard let token = authService.accessToken else { return }
            viewModel.loadHistory(token: token, force: true)
        }
        .onChange(of: viewModel.scrollToTopId) { _, id in
            guard let id else { return }
            scrollTarget = .top(id)
            viewModel.scrollToTopId = nil
        }
        .sheet(isPresented: $showMaterials) {
            DialogMaterialsView(
                peerId: peerId,
                authService: authService,
                vkApi: vkApi
            )
        }
        .sheet(isPresented: $showMembersSheet) {
            membersSheet
        }
        .confirmationDialog("Удалить сообщение?", isPresented: $showDeleteDialog, titleVisibility: .visible) {
            Button("Удалить для всех", role: .destructive) {
                if let msg = pendingDeleteMsg { deleteMessage(msg, forAll: true) }
                pendingDeleteMsg = nil
            }
            Button("Удалить для себя", role: .destructive) {
                if let msg = pendingDeleteMsg { deleteMessage(msg, forAll: false) }
                pendingDeleteMsg = nil
            }
            Button("Отмена", role: .cancel) { pendingDeleteMsg = nil }
        }
        .alert("Переслать сообщение", isPresented: $showForwardStub) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Пересылка сообщений — в разработке.")
        }
        .fullScreenCover(isPresented: $showGallery) {
            let urls = galleryPhotos.compactMap { URL(string: $0.displayURL ?? "") }
            let saveIds = galleryPhotos.compactMap { p -> PhotoSaveId? in
                guard let ownerId = p.ownerId else { return nil }
                return PhotoSaveId(ownerId: ownerId, photoId: p.id, accessKey: p.accessKey)
            }
            FullScreenPhotoGalleryView(
                urls: urls,
                initialIndex: galleryIndex,
                onDismiss: { showGallery = false },
                photoIdsForSaving: saveIds,
                vkApi: vkApi,
                getAccessToken: { authService.accessToken ?? "" }
            )
        }
        .fullScreenCover(item: $videoPlayerRequest) { req in
            VideoPlayerView(url: req.url, onDismiss: { videoPlayerRequest = nil })
        }
        .sheet(
            isPresented: Binding(get: { quickLookURL != nil }, set: { if !$0 { quickLookURL = nil } })
        ) {
            if let url = quickLookURL {
                QuickLookPreview(url: url)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(VKTheme.Colors.textSecondary)
            TextField("Поиск в диалоге", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(VKTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    private var filteredMessages: [VKMessage] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return viewModel.messages
        }
        let q = searchText.lowercased()
        return viewModel.messages.filter { $0.text.lowercased().contains(q) }
    }

    private var messagesList: some View {
        Group {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView("Загрузка…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if viewModel.messages.isEmpty {
                    ContentUnavailableView(
                        "Нет сообщений",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            if viewModel.messages.count < viewModel.totalCount && !isSearchActive {
                                ProgressView("Загрузка старых сообщений…")
                                    .frame(maxWidth: .infinity)
                                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                                    .onAppear {
                                        guard let token = authService.accessToken else { return }
                                        viewModel.loadMoreHistory(token: token)
                                    }
                            }
                            ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { index, msg in
                                let showDate = index == 0 || !Calendar.current.isDate(filteredMessages[index - 1].date, inSameDayAs: msg.date)
                                if showDate {
                                    dateSeparator(msg.date)
                                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                }
                                messageRow(msg)
                                    .id(msg.id)
                                    .background(
                                        highlightedMessageId == msg.id
                                            ? Color.white.opacity(0.5)
                                            : Color.clear
                                    )
                                    .animation(.easeOut(duration: 0.4), value: highlightedMessageId)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .environment(\.defaultMinListRowHeight, 0)
                        .scrollDismissesKeyboard(.immediately)
                        .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
                        .onChange(of: viewModel.messages.count) { _, _ in
                            let newLastId = viewModel.messages.last?.id
                            guard newLastId != lastMessageId else { return }
                            lastMessageId = newLastId
                            if let id = newLastId { scrollTarget = .bottom(id) }
                        }
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                switch target {
                                case .bottom(let id): proxy.scrollTo(id, anchor: .bottom)
                                case .top(let id): proxy.scrollTo(id, anchor: .top)
                                case .message(let id):
                                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                                    highlightedMessageId = id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                        highlightedMessageId = nil
                                    }
                                }
                                scrollTarget = nil
                            }
                        }
                    }
                }
            case .failed(let error):
                ContentUnavailableView(
                    "Ошибка",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(error.localizedDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dateSeparator(_ date: Date) -> some View {
        Text(dateHeaderString(date))
            .font(.system(size: 13))
            .foregroundColor(VKTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    private func dateHeaderString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        let components = cal.dateComponents([.year], from: date, to: Date())
        f.dateFormat = (components.year ?? 0) > 0 ? "d MMMM yyyy" : "d MMMM"
        return f.string(from: date)
    }

    private func messageRow(_ msg: VKMessage) -> some View {
        let isOut = (msg.out ?? 0) == 1
        let deleting = viewModel.deleteInProgress.contains(msg.id)
        let isPinned = viewModel.pinnedMessage?.id == msg.id
        return HStack(alignment: .bottom, spacing: 4) {
            if isOut { Spacer(minLength: 48) }
            if isOut {
                HStack(spacing: 2) {
                    chatReadCheckmarks(isRead: viewModel.outRead > 0 && msg.id <= viewModel.outRead)
                    Text(shortTime(msg.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
            if !isOut {
                incomingAvatar(fromId: msg.fromId)
            }
            VStack(alignment: isOut ? .trailing : .leading, spacing: 2) {
                let photos = (msg.attachments ?? []).compactMap { $0.photo }
                let sticker = (msg.attachments ?? []).first(where: { $0.type == "sticker" })?.sticker
                let wallPosts = (msg.attachments ?? []).compactMap { $0.wall }
                let audioMsg = (msg.attachments ?? []).first(where: { $0.type == "audio_message" })?.audioMessage
                let videos = (msg.attachments ?? []).compactMap { $0.video }
                let docs = (msg.attachments ?? []).compactMap { $0.doc }
                if let sticker = sticker {
                    stickerView(sticker)
                        .opacity(deleting ? 0.5 : 1.0)
                } else if let audioMsg = audioMsg {
                    voiceMessageView(audioMsg, msgId: msg.id, isOut: isOut)
                        .opacity(deleting ? 0.5 : 1.0)
                } else if !videos.isEmpty {
                    VStack(alignment: isOut ? .trailing : .leading, spacing: 4) {
                        if !msg.text.isEmpty {
                            Text(msg.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(isOut ? VKTheme.Colors.incomingBubble : Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        ForEach(Array(videos.enumerated()), id: \.offset) { _, video in
                            videoAttachmentView(video)
                        }
                    }
                    .opacity(deleting ? 0.5 : 1.0)
                } else if !wallPosts.isEmpty {
                    VStack(alignment: isOut ? .trailing : .leading, spacing: 4) {
                        if !msg.text.isEmpty {
                            Text(msg.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: isOut ? .trailing : .leading)
                                .background(isOut ? VKTheme.Colors.incomingBubble : Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        ForEach(Array(wallPosts.enumerated()), id: \.offset) { _, post in
                            wallPostCard(post)
                        }
                    }
                    .opacity(deleting ? 0.5 : 1.0)
                } else {
                    VStack(alignment: isOut ? .trailing : .leading, spacing: 6) {
                        if let reply = msg.replyMessage {
                            HStack(spacing: 6) {
                                Rectangle()
                                    .frame(width: 2)
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 1))
                                Text(reply.text.isEmpty ? "[Фото]" : reply.text)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { scrollTarget = .message(reply.id) }
                        }
                        if !msg.text.isEmpty {
                            Text(msg.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, msg.replyMessage == nil && photos.isEmpty ? 8 : 0)
                                .padding(.top, msg.replyMessage != nil ? 0 : (photos.isEmpty ? 0 : 8))
                                .padding(.bottom, photos.isEmpty ? 8 : 0)
                        }
                        if !photos.isEmpty {
                            messagePhotoGrid(photos, msgId: msg.id)
                                .padding(.top, msg.text.isEmpty && msg.replyMessage == nil ? 0 : 4)
                        }
                        if !docs.isEmpty {
                            ForEach(Array(docs.enumerated()), id: \.offset) { _, doc in
                                docAttachmentView(doc)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 4)
                            }
                        }
                    }
                    .padding(.vertical, msg.text.isEmpty && msg.replyMessage == nil && !photos.isEmpty ? 0 : 0)
                    .background(isOut ? VKTheme.Colors.incomingBubble : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: VKTheme.Radius.bubble))
                    .overlay(
                        RoundedRectangle(cornerRadius: VKTheme.Radius.bubble)
                            .strokeBorder(VKTheme.Colors.separator, lineWidth: VKTheme.Border.card)
                    )
                    .opacity(deleting ? 0.5 : 1.0)
                }
            }
            .contextMenu {
                Button { replyToMessage = msg } label: {
                    Label("Ответить", systemImage: "arrowshape.turn.up.left")
                }
                if !msg.text.isEmpty {
                    Button {
                        UIPasteboard.general.string = msg.text
                    } label: {
                        Label("Скопировать", systemImage: "doc.on.doc")
                    }
                }
                Button { showForwardStub = true } label: {
                    Label("Переслать", systemImage: "arrowshape.turn.up.right")
                }
                // messages.pin в VK API только для бесед (peer_id ≥ 2e9); для личных диалогов пункт не показываем.
                if peerId >= 2_000_000_000 {
                    if isPinned {
                        Button { unpinCurrentMessage() } label: {
                            Label("Открепить", systemImage: "pin.slash")
                        }
                    } else {
                        Button { pinCurrentMessage(msg) } label: {
                            Label("Закрепить", systemImage: "pin")
                        }
                    }
                }
                Divider()
                Button(role: .destructive) {
                    if isOut {
                        pendingDeleteMsg = msg
                        showDeleteDialog = true
                    } else {
                        deleteMessage(msg)
                    }
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
            if !isOut {
                Text(shortTime(msg.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            if !isOut { Spacer(minLength: 48) }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                if isOut {
                    pendingDeleteMsg = msg
                    showDeleteDialog = true
                } else {
                    deleteMessage(msg)
                }
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                replyToMessage = msg
            } label: {
                Label("Ответить", systemImage: "arrowshape.turn.up.left")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func messagePhotoGrid(_ photos: [VKPhoto], msgId: Int) -> some View {
        let columns = photos.count == 1
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(photos.enumerated()), id: \.offset) { idx, photo in
                let thumbUrl = photo.feedPreviewURL.flatMap { URL(string: $0) }
                AsyncImage(url: thumbUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo").resizable().scaledToFit().foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: photos.count == 1 ? 200 : 120)
                .clipped()
                .simultaneousGesture(TapGesture().onEnded {
                    galleryPhotos = photos
                    galleryIndex = idx
                    showGallery = true
                })
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func stickerView(_ sticker: VKSticker) -> some View {
        if let urlStr = sticker.displayURL, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Text("[стикер]")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 128, height: 128)
        } else {
            Text("[стикер]")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func voiceMessageView(_ audio: VKAudioMessage, msgId: Int, isOut: Bool) -> some View {
        let isPlaying = playingAudioMsgId == msgId
        let totalSec = max(audio.duration, 1)
        let elapsed = isPlaying ? Int(audioProgress * Double(totalSec)) : 0
        let displaySec = isPlaying ? elapsed : totalSec
        HStack(spacing: 10) {
            Button {
                toggleAudio(audio, msgId: msgId)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(isOut ? Color.accentColor : Color.primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                if isPlaying {
                    ProgressView(value: audioProgress)
                        .tint(isOut ? Color.accentColor : Color.primary)
                        .frame(width: 140)
                } else {
                    if let waveform = audio.waveform, !waveform.isEmpty {
                        WaveformView(waveform: waveform, isOut: isOut)
                            .frame(width: 140, height: 20)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 140, height: 2)
                    }
                }
                Text(formatDuration(displaySec))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isOut ? VKTheme.Colors.incomingBubble : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: VKTheme.Radius.bubble))
    }

    private func toggleAudio(_ audio: VKAudioMessage, msgId: Int) {
        if playingAudioMsgId == msgId {
            audioPlayer?.pause()
            audioTimer?.invalidate()
            audioTimer = nil
            playingAudioMsgId = nil
            audioProgress = 0
        } else {
            audioPlayer?.pause()
            audioTimer?.invalidate()
            audioTimer = nil
            guard let url = audio.playbackURL else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            let player = AVPlayer(url: url)
            audioPlayer = player
            playingAudioMsgId = msgId
            audioProgress = 0
            player.play()
            let duration = Double(audio.duration)
            audioTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                guard let player = audioPlayer, playingAudioMsgId == msgId else {
                    timer.invalidate()
                    return
                }
                let current = player.currentTime().seconds
                if current.isNaN || current < 0 { return }
                audioProgress = min(current / duration, 1.0)
                if audioProgress >= 1.0 {
                    timer.invalidate()
                    audioTimer = nil
                    playingAudioMsgId = nil
                    audioProgress = 0
                }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private func videoAttachmentView(_ video: VKVideo) -> some View {
        let videoId = video.videoGetId(ownerFallback: 0)
        let isLoading = loadingVideoId == videoId
        ZStack {
            if let previewStr = video.previewImageURL, let previewURL = URL(string: previewStr) {
                AsyncImage(url: previewURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color(.systemGray4)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipped()
            } else {
                Color(.systemGray4).frame(maxWidth: .infinity).frame(height: 160)
            }
            Color.black.opacity(0.3)
            if isLoading {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if let dur = video.duration {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(formatDuration(dur))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 260)
        .simultaneousGesture(TapGesture().onEnded {
            guard !isLoading, let token = authService.accessToken else { return }
            loadingVideoId = videoId
            Task {
                defer { loadingVideoId = nil }
                do {
                    let res = try await vkApi.getVideo(token: token, videos: videoId)
                    if let playerStr = res.items.first?.player, let url = URL(string: playerStr) {
                        videoPlayerRequest = VideoPlayerRequest(url: url)
                    } else {
                        AppLogger.shared.error("video", "No player URL for \(videoId), items: \(res.items.count)")
                    }
                } catch {
                    AppLogger.shared.error("video", "Load failed: \(error)")
                }
            }
        })
    }

    @ViewBuilder
    private func docAttachmentView(_ doc: VKDoc) -> some View {
        let ext = (doc.ext ?? "").uppercased()
        let name = doc.title ?? "Документ"
        let isLoading = loadingDocId == doc.id
        HStack(spacing: 10) {
            Image(systemName: iconForDocExt(doc.ext))
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(2)
                if !ext.isEmpty {
                    Text(ext)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard !isLoading, let urlStr = doc.url, let url = URL(string: urlStr) else { return }
            loadingDocId = doc.id
            Task {
                do {
                    let (localURL, _) = try await URLSession.shared.download(from: url)
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(doc.title ?? "document")
                        .appendingPathExtension(doc.ext ?? "")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: localURL, to: dest)
                    await MainActor.run {
                        loadingDocId = nil
                        quickLookURL = dest
                    }
                } catch {
                    await MainActor.run { loadingDocId = nil }
                }
            }
        })
    }

    private func iconForDocExt(_ ext: String?) -> String {
        switch ext?.lowercased() {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        case "zip", "rar", "7z": return "archivebox"
        case "mp3", "ogg", "flac", "aac": return "music.note"
        case "mp4", "mov", "avi": return "film"
        case "jpg", "jpeg", "png", "gif", "webp": return "photo"
        default: return "doc"
        }
    }

    @ViewBuilder
    private func wallPostCard(_ post: VKPost) -> some View {
        let author = wallPostAuthorName(post)
        let photo = post.attachments?.compactMap { $0.photo }.first
        VStack(alignment: .leading, spacing: 6) {
            Text(author)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(VKTheme.Colors.primary)
            if !post.text.isEmpty {
                Text(post.text)
                    .font(.subheadline)
                    .lineLimit(4)
                    .foregroundStyle(.primary)
            }
            if let photo, let urlStr = photo.feedPreviewURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo").resizable().scaledToFit().foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if post.text.isEmpty && photo == nil {
                Text("[Запись со стены]")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(VKTheme.Colors.primary.opacity(0.4), lineWidth: 1)
        )
    }

    private func wallPostAuthorName(_ post: VKPost) -> String {
        let id = post.fromId ?? post.ownerId ?? 0
        if id > 0 {
            if let p = viewModel.profiles.first(where: { $0.id == id }) {
                let name = [p.firstName, p.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                return name.isEmpty ? "ID\(id)" : name
            }
            return "ID\(id)"
        } else if id < 0 {
            if let g = viewModel.groups.first(where: { $0.id == -id }) {
                return g.name ?? "Сообщество"
            }
            return "Сообщество"
        }
        return "Запись со стены"
    }

    private func pinnedBanner(_ msg: VKMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Закреплённое сообщение")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(msg.text.isEmpty ? "[Фото]" : msg.text)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer()
            Button { unpinCurrentMessage() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    private func pinCurrentMessage(_ msg: VKMessage) {
        guard let token = authService.accessToken else { return }
        Task {
            do {
                try await viewModel.pinMessage(msg, token: token)
            } catch {
                sendError = "Ошибка закрепления: \(error.localizedDescription)"
            }
        }
    }

    private func unpinCurrentMessage() {
        guard let token = authService.accessToken else { return }
        Task {
            do {
                try await viewModel.unpinMessage(token: token)
            } catch {
                sendError = "Ошибка открепления: \(error.localizedDescription)"
            }
        }
    }

    private func replyBanner(_ msg: VKMessage) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ответ на:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(msg.text.isEmpty ? "[Фото]" : msg.text)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                replyToMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
    }

    private func loadAndShowMembers() {
        guard let token = authService.accessToken, !membersLoading else {
            showMembersSheet = true
            return
        }
        membersLoading = true
        showMembersSheet = true
        Task {
            do {
                let result = try await vkApi.getConversationMembers(token: token, peerId: peerId)
                await MainActor.run {
                    membersData = result
                    membersLoading = false
                }
            } catch {
                await MainActor.run { membersLoading = false }
            }
        }
    }

    private var membersSheet: some View {
        NavigationStack {
            Group {
                if membersLoading && membersData == nil {
                    ProgressView("Загрузка…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let data = membersData {
                    let profiles = data.profiles ?? []
                    List(data.items, id: \.memberId) { member in
                        let profile = profiles.first(where: { $0.id == member.memberId })
                        HStack(spacing: 12) {
                            if let urlStr = profile?.photo50, let url = URL(string: urlStr) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let img): img.resizable().scaledToFill()
                                    default: Color(.systemGray4)
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(.systemGray4))
                                    .frame(width: 40, height: 40)
                                    .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                let name: String = {
                                    guard let p = profile else { return "ID\(member.memberId)" }
                                    let n = [p.firstName, p.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                                    return n.isEmpty ? "ID\(member.memberId)" : n
                                }()
                                Text(name)
                                    .font(VKTheme.TextStyle.dialogName)
                                    .foregroundStyle(VKTheme.Colors.textPrimary)
                                if member.isAdmin == true {
                                    Text("Администратор")
                                        .font(VKTheme.TextStyle.timestamp)
                                        .foregroundStyle(VKTheme.Colors.primary)
                                } else if member.isOwner == true {
                                    Text("Создатель")
                                        .font(VKTheme.TextStyle.timestamp)
                                        .foregroundStyle(VKTheme.Colors.primary)
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView("Нет данных", systemImage: "person.2")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Участники беседы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { showMembersSheet = false }
                }
            }
        }
    }

    private func deleteMessage(_ msg: VKMessage, forAll: Bool = false) {
        guard let token = authService.accessToken else { return }
        Task {
            do {
                try await viewModel.deleteMessage(msg, token: token, deleteForAll: forAll)
            } catch {
                sendError = "Ошибка удаления: \(error.localizedDescription)"
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    showAttachMenu = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundColor(VKTheme.Colors.textSecondary)
                }
                .disabled(sending)
                .sheet(isPresented: $showAttachMenu) {
                    attachMenu
                        .presentationDetents([.height(120)])
                        .presentationDragIndicator(.visible)
                }

                TextField("Ваше сообщение...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .focused($inputFocused)

                Button {
                    showStickerPicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20))
                        .foregroundColor(VKTheme.Colors.textSecondary)
                }
                .disabled(sending)
                .sheet(isPresented: $showStickerPicker) {
                    StickerPickerView(authService: authService) { stickerId in
                        Task { await sendSticker(stickerId) }
                    }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }

                let canSend = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
                Button {
                    sendMessage()
                } label: {
                    if sending {
                        ProgressView()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(canSend ? VKTheme.Colors.primary : VKTheme.Colors.textSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: VKTheme.Radius.button))
                    }
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white)
        }
    }

    private var attachMenu: some View {
        VStack(spacing: 0) {
            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Фото из галереи", systemImage: "photo")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                showAttachMenu = false
                guard let item = newItem else { return }
                Task { await sendPhoto(from: item) }
            }
            Divider()
        }
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    @ViewBuilder
    private func chatReadCheckmarks(isRead: Bool) -> some View {
        if isRead {
            ZStack {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .offset(x: -2)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .offset(x: 2)
            }
            .foregroundColor(VKTheme.Colors.primary)
            .frame(width: 14, height: 12)
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let token = authService.accessToken else { return }
        sending = true
        sendError = nil
        let randomId = Int.random(in: 1...Int.max)
        let replyId = replyToMessage?.id
        Task {
            do {
                let messageId = try await vkApi.sendMessage(token: token, peerId: peerId, message: text, randomId: randomId, replyTo: replyId)
                let fromId = viewModel.outgoingFromId()
                let newMsg = VKMessage(
                    id: messageId,
                    fromId: fromId,
                    peerId: peerId,
                    date: Date(),
                    text: text,
                    out: 1,
                    readState: nil
                )
                inputText = ""
                replyToMessage = nil
                sending = false
                viewModel.appendMessage(newMsg)
            } catch {
                sending = false
                sendError = error.localizedDescription
            }
        }
    }

    private func sendPhoto(from item: PhotosPickerItem) async {
        guard let token = authService.accessToken else {
            sendError = "Нет доступа"
            return
        }
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            guard let imageData = try await item.loadTransferable(type: ChatImageDataTransfer.self) else {
                sendError = "Не удалось загрузить фото"
                return
            }
            let jpegData = imageData.dataAsJpeg
            let uploadUrl = try await vkApi.getMessagesUploadServer(token: token, peerId: peerId)
            let (server, hash, photo) = try await vkApi.uploadMessagesPhotoToServer(uploadUrl: uploadUrl, imageData: jpegData)
            let saved = try await vkApi.saveMessagesPhoto(token: token, server: server, hash: hash, photo: photo)
            let attachment = "photo\(saved.ownerId)_\(saved.id)"
            let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let messageId = try await vkApi.sendMessage(token: token, peerId: peerId, message: text, randomId: Int.random(in: 1...Int.max), attachment: attachment)
            let fromId = viewModel.outgoingFromId()
            let newMsg = VKMessage(id: messageId, fromId: fromId, peerId: peerId, date: Date(), text: text.isEmpty ? "[Фото]" : text, out: 1, readState: nil)
            inputText = ""
            viewModel.appendMessage(newMsg)
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func sendSticker(_ stickerId: Int) async {
        guard let token = authService.accessToken, !token.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            let messageId = try await vkApi.sendSticker(token: token, peerId: peerId, stickerId: stickerId)
            let fromId = viewModel.outgoingFromId()
            let newMsg = VKMessage(id: messageId, fromId: fromId, peerId: peerId, date: Date(), text: "", out: 1, readState: nil)
            viewModel.appendMessage(newMsg)
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct ChatImageDataTransfer: Transferable {
    let data: Data
    var dataAsJpeg: Data {
        if let ui = UIImage(data: data), let jpeg = ui.jpegData(compressionQuality: 0.9) { return jpeg }
        if let ui = decodeImageFromData(data), let jpeg = ui.jpegData(compressionQuality: 0.9) { return jpeg }
        return data
    }
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in ChatImageDataTransfer(data: data) }
    }
}

private func decodeImageFromData(_ data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cgImage)
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

private struct WaveformView: View {
    let waveform: [Int]
    let isOut: Bool

    var body: some View {
        let bars = stride(from: 0, to: waveform.count, by: max(1, waveform.count / 30)).map { waveform[$0] }
        let maxVal = bars.max() ?? 1
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, val in
                    let h = max(2, geo.size.height * CGFloat(val) / CGFloat(maxVal))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isOut ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.6))
                        .frame(width: 2, height: h)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
