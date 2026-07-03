import SwiftUI
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    let peerId: Int

    @Published private(set) var messages: [VKMessage] = []
    @Published private(set) var profiles: [VKProfile] = []
    @Published private(set) var groups: [VKGroup] = []
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var isLoadingMore: Bool = false
    @Published private(set) var pinnedMessage: VKMessage? = nil
    @Published private(set) var deleteInProgress: Set<Int> = []
    /// Выставляется после loadMoreHistory — вид прокручивает к этому id, затем сбрасывает в nil.
    @Published var scrollToTopId: Int? = nil
    /// ID последнего исходящего сообщения, прочитанного собеседником (из conversation.out_read).
    @Published var outRead: Int = 0

    private(set) var lastMessageId: Int? = nil
    private let vkApi = VKApiService()
    let pageSize = 30

    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(Error)
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.loaded, .loaded), (.failed, .failed): return true
            default: return false
            }
        }
    }

    init(peerId: Int) {
        self.peerId = peerId
    }

    func loadHistory(token: String, force: Bool = false) {
        if !force, case .loaded = loadState {
            AppLogger.shared.info("Chat", "peerId=\(peerId) already loaded, skip")
            return
        }
        if !force, case .loading = loadState { return }
        AppLogger.shared.info("Chat", "peerId=\(peerId) loading history (force=\(force))")
        loadState = .loading
        Task {
            do {
                let res = try await vkApi.getHistory(token: token, peerId: peerId, count: pageSize, offset: 0)
                messages = res.items.reversed()
                totalCount = res.count
                profiles = res.profiles ?? []
                groups = res.groups ?? []
                loadState = .loaded
                lastMessageId = messages.last?.id
            } catch {
                loadState = .failed(error)
            }
        }
    }

    func loadMoreHistory(token: String) {
        guard case .loaded = loadState, messages.count < totalCount, !isLoadingMore else { return }
        isLoadingMore = true
        let offset = messages.count
        let topId = messages.first?.id
        Task {
            do {
                let res = try await vkApi.getHistory(token: token, peerId: peerId, count: pageSize, offset: offset)
                let older = Array(res.items.reversed())
                messages = older + messages
                if res.items.isEmpty { totalCount = messages.count }
                isLoadingMore = false
                scrollToTopId = topId
            } catch {
                isLoadingMore = false
            }
        }
    }

    func appendMessage(_ msg: VKMessage) {
        withAnimation(.default) {
            messages.append(msg)
            totalCount += 1
        }
    }

    func deleteMessage(_ msg: VKMessage, token: String, deleteForAll: Bool = false) async throws {
        deleteInProgress.insert(msg.id)
        do {
            try await vkApi.deleteMessages(token: token, messageIds: [msg.id], deleteForAll: deleteForAll)
            messages.removeAll { $0.id == msg.id }
            totalCount = max(0, totalCount - 1)
            deleteInProgress.remove(msg.id)
        } catch {
            deleteInProgress.remove(msg.id)
            throw error
        }
    }

    func pinMessage(_ msg: VKMessage, token: String) async throws {
        let pinned = try await vkApi.pinMessage(token: token, peerId: peerId, messageId: msg.id)
        pinnedMessage = pinned
    }

    func unpinMessage(token: String) async throws {
        try await vkApi.unpinMessage(token: token, peerId: peerId)
        pinnedMessage = nil
    }

    func outgoingFromId() -> Int {
        messages.first(where: { ($0.out ?? 0) == 1 })?.fromId ?? 0
    }
}

/// Кэш ChatViewModel по peerId — живёт пока жив MessagesTabView.
/// ObservableObject нужен чтобы использовать @StateObject в SwiftUI-структуре.
@MainActor
final class ChatViewModelCache: ObservableObject {
    private var cache: [Int: ChatViewModel] = [:]

    func viewModel(for peerId: Int) -> ChatViewModel {
        if let vm = cache[peerId] { return vm }
        let vm = ChatViewModel(peerId: peerId)
        cache[peerId] = vm
        return vm
    }
}
