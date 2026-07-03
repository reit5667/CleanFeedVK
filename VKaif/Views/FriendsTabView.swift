import SwiftUI

/// Вкладка «Друзья» в таббаре: список с поиском, исходящие/входящие заявки, возможные друзья.
struct FriendsTabView: View {
    @ObservedObject var authService: AuthService

    enum Segment: String, CaseIterable {
        case all = "Все"
        case outgoing = "Исходящие"
        case incoming = "Входящие"
        case suggestions = "Возможные"
    }

    @State private var segment: Segment = .all
    @State private var searchText = ""
    @State private var friends: [VKFriend] = []
    @State private var outgoingUsers: [VKUserDetail] = []
    @State private var incomingUsers: [VKUserDetail] = []
    @State private var suggestions: [VKFriend] = []
    @State private var loadState: LoadState = .idle

    private let vkApi = VKApiService()

    enum LoadState {
        case idle
        case loading
        case loaded
        case failed(Error)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { seg in
                    Text(seg.rawValue).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .onChange(of: segment) { _, _ in loadSegment() }

            if segment == .all {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Поиск", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(.systemGray6))
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            Group {
                switch loadState {
                case .idle, .loading:
                    ProgressView(segment == .all ? "Загрузка друзей…" : "Загрузка…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded:
                    listContent
                case .failed(let error):
                    ContentUnavailableView(
                        "Ошибка",
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text(error.localizedDescription)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Друзья")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSegment() }
        .refreshable { loadSegment(force: true) }
        .navigationDestination(for: Int.self) { userId in
            ProfileViewWrapper(authService: authService, userId: userId)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        let filtered = currentList
        if filtered.isEmpty {
            ContentUnavailableView(
                segment == .all ? "Нет друзей" : emptyTitle,
                systemImage: segment == .suggestions ? "person.2" : "person.badge.plus"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.userId) { item in
                        NavigationLink(value: item.userId) {
                            HStack(spacing: 12) {
                                avatarView(url: item.photoURL)
                                Text(item.name)
                                    .font(.body)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .padding(.leading, 44 + 12 + 16)
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        switch segment {
        case .all: return "Нет друзей"
        case .outgoing: return "Нет исходящих заявок"
        case .incoming: return "Нет входящих заявок"
        case .suggestions: return "Нет рекомендаций"
        }
    }

    private struct DisplayItem {
        let userId: Int
        let name: String
        let photoURL: String?
    }

    private var currentList: [DisplayItem] {
        switch segment {
        case .all:
            return friends.filter { searchText.isEmpty || $0.displayName.localizedCaseInsensitiveContains(searchText) }
                .map { DisplayItem(userId: $0.id, name: $0.displayName, photoURL: $0.photo50) }
        case .outgoing:
            return outgoingUsers.map { DisplayItem(userId: $0.id, name: $0.displayName, photoURL: $0.avatarURL) }
        case .incoming:
            return incomingUsers.map { DisplayItem(userId: $0.id, name: $0.displayName, photoURL: $0.avatarURL) }
        case .suggestions:
            return suggestions.map { DisplayItem(userId: $0.id, name: $0.displayName, photoURL: $0.photo50) }
        }
    }

    private func avatarView(url: String?) -> some View {
        Group {
            if let urlString = url, let url = URL(string: urlString) {
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

    private func loadSegment(force: Bool = false) {
        guard let token = authService.accessToken else {
            loadState = .failed(VKApiError.missingToken)
            return
        }
        loadState = .loading
        Task {
            do {
                switch segment {
                case .all:
                    let res = try await vkApi.getFriends(token: token, count: 5000, offset: 0)
                    await MainActor.run {
                        friends = res.items
                        loadState = .loaded
                    }
                case .outgoing:
                    let res = try await vkApi.getFriendsRequests(token: token, count: 100, out: 1)
                    let users = res.items.isEmpty ? [] : try await vkApi.getUsers(token: token, userIds: res.items.map { String($0) })
                    await MainActor.run {
                        outgoingUsers = users
                        loadState = .loaded
                    }
                case .incoming:
                    let res = try await vkApi.getFriendsRequests(token: token, count: 100, out: 0)
                    let users = res.items.isEmpty ? [] : try await vkApi.getUsers(token: token, userIds: res.items.map { String($0) })
                    await MainActor.run {
                        incomingUsers = users
                        loadState = .loaded
                    }
                case .suggestions:
                    let res = try await vkApi.getFriendsSuggestions(token: token, count: 100)
                    await MainActor.run {
                        suggestions = res.items
                        loadState = .loaded
                    }
                }
            } catch {
                await MainActor.run { loadState = .failed(error) }
            }
        }
    }
}
