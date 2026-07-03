import Foundation

// MARK: - VK API Errors

enum VKApiError: Error, LocalizedError {
    case missingToken
    case invalidURL
    case apiError(code: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Нет токена доступа"
        case .invalidURL: return "Неверный URL"
        case .apiError(let code, let msg): return msg ?? "Ошибка VK \(code)"
        }
    }
}

// MARK: - VK API Service

/// Обёртка над NetworkService: строит URL для методов VK API.
/// Токен передаётся в каждый вызов (удобно для вызова из MainActor).
final class VKApiService: Sendable {

    private let baseURL = "https://api.vk.com/method"
    private let apiVersion = "5.131"

    private let network: any NetworkServiceProtocol
    private let logger: (any AppLogging)?
    private let decoder = JSONDecoder()

    init(
        network: any NetworkServiceProtocol = NetworkService(),
        logger: (any AppLogging)? = AppLogger.shared
    ) {
        self.network = network
        self.logger = logger
    }

    /// Запрос к VK API с разбором ошибки: при { "error": { "error_code", "error_msg" } } бросает VKApiError.apiError.
    private func requestVK<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger?.error("VKApi", "invalid response (not HTTPURLResponse)")
            throw NetworkError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            logger?.error("VKApi", "HTTP \(http.statusCode)", error: nil)
            throw NetworkError.httpStatus(http.statusCode, data)
        }
        if let errWrapper = try? decoder.decode(VKErrorWrapper.self, from: data) {
            let msg = errWrapper.error.errorMsg ?? "Ошибка VK \(errWrapper.error.errorCode)"
            logger?.error("VKApi", "API error \(errWrapper.error.errorCode): \(msg)", error: nil)
            throw VKApiError.apiError(code: errWrapper.error.errorCode, message: errWrapper.error.errorMsg)
        }
        do {
            let wrapper = try decoder.decode(VKResponse<T>.self, from: data)
            return wrapper.response
        } catch {
            if let body = String(data: data, encoding: .utf8) {
                let preview = body.count > 500 ? String(body.prefix(500)) + "…" : body
                logger?.error("VKApi", "decode failed, response: \(preview)", error: error)
            }
            throw error
        }
    }

    // MARK: - newsfeed.get

    /// Загружает ленту (только посты: filters=post).
    /// - Parameters:
    ///   - token: access_token из AuthService.
    ///   - startFrom: курсор пагинации (nil = первая страница).
    func getNewsfeed(token: String, startFrom: String? = nil) async throws -> NewsfeedGetResponse {
        guard !token.isEmpty else {
            logger?.error("VKApi", "getNewsfeed: empty token")
            throw VKApiError.missingToken
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "filters", value: "post"),
            URLQueryItem(name: "count", value: "20")
        ]
        if let from = startFrom, !from.isEmpty {
            queryItems.append(URLQueryItem(name: "start_from", value: from))
        }

        guard var components = URLComponents(string: "\(baseURL)/newsfeed.get") else {
            throw VKApiError.invalidURL
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw VKApiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        logger?.info("VKApi", "newsfeed.get startFrom=\(startFrom ?? "nil")")

        // VK может вернуть { "error": { "error_code": 5, "error_msg": "..." } } вместо response
        let wrapper: VKResponse<NewsfeedGetResponse>
        do {
            wrapper = try await network.request(VKResponse<NewsfeedGetResponse>.self, from: request)
        } catch {
            logger?.error("VKApi", "newsfeed.get failed", error: error)
            throw error
        }

        logger?.info("VKApi", "newsfeed.get ok, items=\(wrapper.response.items.count)")
        if let first = wrapper.response.items.first {
            logger?.info("VKApi", "newsfeed.get first post: postId=\(first.postId) likes=\(first.likesCount) comments=\(first.commentsCount)")
        }
        return wrapper.response
    }

    // MARK: - users.get

    /// Загружает профили пользователей. Без userIds — текущий пользователь.
    /// - Parameters:
    ///   - token: access_token.
    ///   - userIds: ID или screen_name; nil/пусто = текущий пользователь.
    ///   - fields: доп. поля (photo_200, status и т.д.).
    func getUsers(
        token: String,
        userIds: [String]? = nil,
        fields: String = "photo_200,photo_400,photo_max,photo_max_orig,status,online,last_seen,verified,sex,counters,followers_count,bdate,city,country,home_town,relation,relation_partner,relatives,site,about"
    ) async throws -> [VKUserDetail] {
        guard !token.isEmpty else {
            logger?.error("VKApi", "getUsers: empty token")
            throw VKApiError.missingToken
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "fields", value: fields)
        ]
        if let ids = userIds, !ids.isEmpty {
            queryItems.append(URLQueryItem(name: "user_ids", value: ids.joined(separator: ",")))
        }

        guard var components = URLComponents(string: "\(baseURL)/users.get") else {
            throw VKApiError.invalidURL
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw VKApiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        logger?.info("VKApi", "users.get userIds=\(userIds?.joined(separator: ",") ?? "current")")

        let wrapper: VKResponse<[VKUserDetail]>
        do {
            wrapper = try await network.request(VKResponse<[VKUserDetail]>.self, from: request)
        } catch {
            logger?.error("VKApi", "users.get failed", error: error)
            throw error
        }

        logger?.info("VKApi", "users.get ok, count=\(wrapper.response.count)")
        return wrapper.response
    }

    // MARK: - photos.getAlbums

    /// Альбомы пользователя (ownerId = nil — текущий). need_covers=1 — превью в items.
    func getPhotosAlbums(
        token: String,
        ownerId: Int? = nil,
        count: Int = 50,
        offset: Int = 0,
        needCovers: Int = 1
    ) async throws -> PhotosGetAlbumsResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "need_covers", value: String(needCovers)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if let oid = ownerId { queryItems.append(URLQueryItem(name: "owner_id", value: String(oid))) }
        guard var components = URLComponents(string: "\(baseURL)/photos.getAlbums") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "photos.getAlbums ownerId=\(ownerId.map { String($0) } ?? "current")")
        let response = try await requestVK(PhotosGetAlbumsResponse.self, from: request)
        logger?.info("VKApi", "photos.getAlbums ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - photos.get

    /// Фото альбома. album_id: числовой или -15 для «Сохранённые». rev: 1 = сначала новые, 0 = сначала старые.
    func getPhotos(
        token: String,
        ownerId: Int,
        albumId: Int,
        count: Int = 50,
        offset: Int = 0,
        rev: Int = 1
    ) async throws -> PhotosGetResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "album_id", value: String(albumId)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rev", value: String(rev)),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "photo_sizes", value: "1")
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.get") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let wrapper: VKResponse<PhotosGetResponse> = try await network.request(VKResponse<PhotosGetResponse>.self, from: request)
        return wrapper.response
    }

    /// Главное фото профиля (альбом «Фото профиля», album_id = -6). Первое фото в альбоме — в полном размере (sizes), не миниатюра из users.get.
    func getProfileMainPhoto(token: String, ownerId: Int) async throws -> VKPhoto? {
        let response = try await getPhotos(token: token, ownerId: ownerId, albumId: -6, count: 1, offset: 0, rev: 1)
        return response.items.first
    }

    // MARK: - photos.getAll

    /// Все фото пользователя или сообщества (без указания альбома). Используется для фотостипа группы и счётчика фото.
    func getPhotosAll(token: String, ownerId: Int, count: Int = 5, offset: Int = 0) async throws -> PhotosGetResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "photo_sizes", value: "1")
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.getAll") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "photos.getAll ownerId=\(ownerId)")
        let wrapper: VKResponse<PhotosGetResponse> = try await network.request(VKResponse<PhotosGetResponse>.self, from: request)
        logger?.info("VKApi", "photos.getAll ok total=\(wrapper.response.count) loaded=\(wrapper.response.items.count)")
        return wrapper.response
    }

    // MARK: - photos.getById

    /// Полные данные фото по списку (ownerId_photoId). Используется для обогащения стабов из newsfeed.get.
    /// VK принимает до 1000 id за раз; access_key добавляется если есть.
    func photosGetById(token: String, photoRefs: [(ownerId: Int, photoId: Int, accessKey: String?)]) async throws -> [VKPhoto] {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        guard !photoRefs.isEmpty else { return [] }
        let ids = photoRefs.map { ref -> String in
            if let key = ref.accessKey, !key.isEmpty {
                return "\(ref.ownerId)_\(ref.photoId)_\(key)"
            }
            return "\(ref.ownerId)_\(ref.photoId)"
        }.joined(separator: ",")
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "photos", value: ids),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "photo_sizes", value: "1")
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.getById") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "photos.getById count=\(photoRefs.count)")
        let wrapper: VKResponse<[VKPhoto]> = try await network.request(VKResponse<[VKPhoto]>.self, from: request)
        logger?.info("VKApi", "photos.getById ok returned=\(wrapper.response.count)")
        return wrapper.response
    }

    // MARK: - friends.get

    /// Список друзей (userId = nil — текущий). extended=1 — полные объекты с полями.
    func getFriends(
        token: String,
        userId: Int? = nil,
        count: Int = 50,
        offset: Int = 0,
        extended: Int = 1,
        fields: String = "photo_50"
    ) async throws -> FriendsGetResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "extended", value: String(extended)),
            URLQueryItem(name: "order", value: "name"),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "fields", value: fields)
        ]
        if let uid = userId { queryItems.append(URLQueryItem(name: "user_id", value: String(uid))) }
        guard var components = URLComponents(string: "\(baseURL)/friends.get") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "friends.get userId=\(userId.map { String($0) } ?? "current")")
        let response = try await requestVK(FriendsGetResponse.self, from: request)
        logger?.info("VKApi", "friends.get ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - friends.getRequests

    /// Заявки в друзья. out: 0 = входящие (default), 1 = исходящие. Возвращает массив id.
    func getFriendsRequests(
        token: String,
        offset: Int = 0,
        count: Int = 50,
        out: Int = 0
    ) async throws -> FriendsGetRequestsResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "out", value: String(out))
        ]
        guard var components = URLComponents(string: "\(baseURL)/friends.getRequests") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "friends.getRequests out=\(out)")
        let response = try await requestVK(FriendsGetRequestsResponse.self, from: request)
        logger?.info("VKApi", "friends.getRequests ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - friends.getSuggestions

    /// Возможные друзья (рекомендации).
    func getFriendsSuggestions(
        token: String,
        offset: Int = 0,
        count: Int = 50,
        fields: String = "photo_50"
    ) async throws -> FriendsGetSuggestionsResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "fields", value: fields)
        ]
        guard var components = URLComponents(string: "\(baseURL)/friends.getSuggestions") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "friends.getSuggestions")
        let response = try await requestVK(FriendsGetSuggestionsResponse.self, from: request)
        logger?.info("VKApi", "friends.getSuggestions ok count=\(response.count)")
        return response
    }

    // MARK: - groups.get

    /// Сообщества текущего пользователя (все типы: группы, паблики, мероприятия). Без filter — все подписки, как в друзьях.
    func getGroups(
        token: String,
        count: Int = 1000,
        offset: Int = 0,
        extended: Int = 1
    ) async throws -> GroupsGetResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "extended", value: String(extended)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "fields", value: "activity,photo_50")
        ]
        guard var components = URLComponents(string: "\(baseURL)/groups.get") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "groups.get")
        let response = try await requestVK(GroupsGetResponse.self, from: request)
        logger?.info("VKApi", "groups.get ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - groups.getById

    /// Информация о группе по ID (положительный id, например 12345) с расширенными полями.
    func getGroupById(token: String, groupId: Int) async throws -> VKGroup? {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "group_ids", value: String(groupId)),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "fields", value: "description,members_count,activity,status,photo_200")
        ]
        guard var components = URLComponents(string: "\(baseURL)/groups.getById") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "groups.getById groupId=\(groupId)")
        let groups: [VKGroup] = try await requestVK([VKGroup].self, from: request)
        logger?.info("VKApi", "groups.getById ok count=\(groups.count)")
        return groups.first
    }

    // MARK: - groups.leave

    /// Отписаться от группы (выйти из сообщества). group_id — положительный ID группы.
    func leaveGroup(token: String, groupId: Int) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        guard groupId > 0 else { throw VKApiError.apiError(code: -1, message: "Некорректный ID группы") }
        let bodyItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "group_id", value: String(groupId))
        ]
        guard let url = URL(string: "\(baseURL)/groups.leave") else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = bodyItems.compactMap { item -> String? in
            guard let val = item.value else { return nil }
            let enc = val.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? val
            return "\(item.name)=\(enc)"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        logger?.info("VKApi", "groups.leave POST groupId=\(groupId)")
        let (data, resp) = try await network.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else { throw NetworkError.httpStatus(http.statusCode, data) }
        if let errWrapper = try? decoder.decode(VKErrorWrapper.self, from: data) {
            let msg = errWrapper.error.errorMsg ?? "Ошибка VK \(errWrapper.error.errorCode)"
            logger?.error("VKApi", "groups.leave API error \(errWrapper.error.errorCode): \(msg)")
            throw VKApiError.apiError(code: errWrapper.error.errorCode, message: errWrapper.error.errorMsg)
        }
        logger?.info("VKApi", "groups.leave ok groupId=\(groupId)")
    }

    // MARK: - wall.get

    /// Стена: посты группы (ownerId < 0) или пользователя (ownerId > 0). extended=1 — profiles и groups для имён/аватаров репостов.
    func getWall(
        token: String,
        ownerId: Int,
        count: Int = 20,
        offset: Int = 0,
        extended: Int = 1
    ) async throws -> WallGetResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "extended", value: String(extended))
        ]
        guard var components = URLComponents(string: "\(baseURL)/wall.get") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "wall.get ownerId=\(ownerId)")
        let response = try await requestVK(WallGetResponse.self, from: request)
        logger?.info("VKApi", "wall.get ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - wall.getComments

    /// Комментарии к посту. ownerId — владелец стены (знак сохраняется: группа отрицательная).
    /// sort: asc (старые первые) или desc (новые первые). Пагинация: offset, count (по 5).
    /// threadItemsCount — сколько ответов подтягивать в thread каждого комментария (0 = не подтягивать).
    func getWallComments(
        token: String,
        ownerId: Int,
        postId: Int,
        offset: Int = 0,
        count: Int = 5,
        sort: String = "asc",
        needLikes: Int = 1,
        extended: Int = 1,
        threadItemsCount: Int = 10
    ) async throws -> WallGetCommentsResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "post_id", value: String(postId)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "need_likes", value: String(needLikes)),
            URLQueryItem(name: "extended", value: String(extended)),
            URLQueryItem(name: "thread_items_count", value: String(threadItemsCount)),
            URLQueryItem(name: "fields", value: "photo_50")
        ]
        guard var components = URLComponents(string: "\(baseURL)/wall.getComments") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "wall.getComments ownerId=\(ownerId) postId=\(postId) offset=\(offset)")
        let response = try await requestVK(WallGetCommentsResponse.self, from: request)
        logger?.info("VKApi", "wall.getComments ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - photos.getComments

    /// Комментарии к фото. Формат ответа совпадает с wall.getComments.
    func getPhotoComments(
        token: String,
        ownerId: Int,
        photoId: Int,
        offset: Int = 0,
        count: Int = 20,
        sort: String = "asc",
        needLikes: Int = 1,
        extended: Int = 1
    ) async throws -> WallGetCommentsResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "photo_id", value: String(photoId)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "need_likes", value: String(needLikes)),
            URLQueryItem(name: "extended", value: String(extended))
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.getComments") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "photos.getComments ownerId=\(ownerId) photoId=\(photoId)")
        let response = try await requestVK(WallGetCommentsResponse.self, from: request)
        logger?.info("VKApi", "photos.getComments ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - photos.copy

    /// Скопировать фото в «Сохранённые» пользователя. owner_id и photo_id — владелец и id фото.
    /// accessKey — строка (для опционального передавать photo.accessKey ?? ""), чтобы не разыменовывать optional в async и избежать EXC_BAD_ACCESS.
    func photosCopy(
        token: String,
        ownerId: Int,
        photoId: Int,
        accessKey: String = ""
    ) async throws -> PhotosCopyResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "photo_id", value: String(photoId))
        ]
        if !accessKey.isEmpty {
            queryItems.append(URLQueryItem(name: "access_key", value: accessKey))
        }
        guard var components = URLComponents(string: "\(baseURL)/photos.copy") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "photos.copy ownerId=\(ownerId) photoId=\(photoId)")
        let response = try await requestVK(PhotosCopyResponse.self, from: request)
        logger?.info("VKApi", "photos.copy ok newOwnerId=\(response.ownerId) newId=\(response.id)")
        return response
    }

    // MARK: - photos.delete

    /// Удалить фото. owner_id — владелец (пользователь или -groupId), photo_id — id фото. Возвращает 1 при успехе.
    func photosDelete(
        token: String,
        ownerId: Int,
        photoId: Int
    ) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "photo_id", value: String(photoId))
        ]
        // POST: VK требует POST для деструктивных методов; при GET возвращает 1 но не удаляет (особенно для photo_id > Int32.max)
        guard let url = URL(string: "\(baseURL)/photos.delete") else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = queryItems.compactMap { item -> String? in
            guard let val = item.value else { return nil }
            let encVal = val.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? val
            return "\(item.name)=\(encVal)"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        logger?.info("VKApi", "photos.delete POST ownerId=\(ownerId) photoId=\(photoId)")
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger?.error("VKApi", "photos.delete invalid response (not HTTPURLResponse)")
            throw NetworkError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let preview = String(data: data, encoding: .utf8).map { $0.count > 500 ? String($0.prefix(500)) + "…" : $0 } ?? "nil"
            logger?.error("VKApi", "photos.delete HTTP \(http.statusCode): \(preview)")
            throw NetworkError.httpStatus(http.statusCode, data)
        }
        if let errWrapper = try? decoder.decode(VKErrorWrapper.self, from: data) {
            let msg = errWrapper.error.errorMsg ?? "Ошибка VK \(errWrapper.error.errorCode)"
            logger?.error("VKApi", "photos.delete API error \(errWrapper.error.errorCode): \(msg)")
            throw VKApiError.apiError(code: errWrapper.error.errorCode, message: errWrapper.error.errorMsg)
        }
        do {
            let wrapper = try decoder.decode(VKResponse<Int>.self, from: data)
            let preview = String(data: data, encoding: .utf8).map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 } ?? "nil"
            logger?.info("VKApi", "photos.delete ok response=\(wrapper.response) raw=\(preview)")
        } catch {
            let preview = String(data: data, encoding: .utf8).map { $0.count > 500 ? String($0.prefix(500)) + "…" : $0 } ?? "nil"
            logger?.error("VKApi", "photos.delete decode failed raw=\(preview)", error: error)
            throw error
        }
    }

    // MARK: - photos.makeCover

    /// Сделать фото обложкой альбома. Для альбома «Фото профиля» (albumId: -6) — главное фото в шапке профиля. VK API требует album_id.
    func photosMakeCover(
        token: String,
        ownerId: Int,
        photoId: Int,
        albumId: Int = -6
    ) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "photo_id", value: String(photoId)),
            URLQueryItem(name: "album_id", value: String(albumId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.makeCover") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "photos.makeCover ownerId=\(ownerId) photoId=\(photoId) albumId=\(albumId)")
        let _: Int = try await requestVK(Int.self, from: request)
        logger?.info("VKApi", "photos.makeCover ok")
    }

    // MARK: - photos.getOwnerPhotoUploadServer / photos.saveOwnerPhoto (загрузка фото профиля)

    /// Получить URL для загрузки фото профиля (владельца). Дальше POST изображения на upload_url.
    func getOwnerPhotoUploadServer(token: String) async throws -> String {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion)
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.getOwnerPhotoUploadServer") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let response = try await requestVK(OwnerPhotoUploadServerResponse.self, from: request)
        guard !response.uploadUrl.isEmpty else { throw VKApiError.apiError(code: -1, message: "Пустой upload_url") }
        return response.uploadUrl
    }

    /// Сохранить загруженное фото как фото профиля. Параметры — из ответа POST на upload_url.
    func saveOwnerPhoto(token: String, server: String, hash: String, photo: String) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "server", value: server),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "photo", value: photo)
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.saveOwnerPhoto") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let _: Int = try await requestVK(Int.self, from: request)
        logger?.info("VKApi", "photos.saveOwnerPhoto ok")
    }

    /// Загрузить изображение (Data) на upload_url VK (multipart/form-data, поле "photo"). Возвращает server, photo, hash для saveOwnerPhoto.
    func uploadOwnerPhotoToServer(uploadUrl: String, imageData: Data) async throws -> (server: String, hash: String, photo: String) {
        guard let url = URL(string: uploadUrl) else { throw VKApiError.invalidURL }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, _) = try await network.data(for: request)
        let result = try decoder.decode(OwnerPhotoUploadResult.self, from: data)
        guard let server = result.server, let hash = result.hash, let photo = result.photo else {
            throw VKApiError.apiError(code: -1, message: "Некорректный ответ загрузки")
        }
        return (server, hash, photo)
    }

    // MARK: - video.get

    /// Получить видео по идентификатору "owner_id_video_id" (например "123_456"). Возвращает превью (image/first_frame) и player URL.
    func getVideo(
        token: String,
        videos: String
    ) async throws -> VideoGetResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [
            URLQueryItem
        ] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "videos", value: videos)
        ]
        guard var components = URLComponents(string: "\(baseURL)/video.get") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "video.get videos=\(videos)")
        let response = try await requestVK(VideoGetResponse.self, from: request)
        logger?.info("VKApi", "video.get ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - polls.addVote

    /// Проголосовать в опросе. owner_id — владелец опроса (отрицательный для группы). answer_ids — один id для одиночного выбора.
    /// Возвращает 1 при успехе.
    func addPollVote(
        token: String,
        ownerId: Int,
        pollId: Int,
        answerId: Int
    ) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "poll_id", value: String(pollId)),
            URLQueryItem(name: "answer_ids", value: String(answerId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/polls.addVote") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "polls.addVote ownerId=\(ownerId) pollId=\(pollId) answerId=\(answerId)")
        let _: Int = try await requestVK(Int.self, from: request)
        logger?.info("VKApi", "polls.addVote ok")
    }

    // MARK: - likes.add

    /// Ставить лайк на пост или комментарий. type: "post" | "comment". item_id — id поста или комментария.
    /// Возвращает новое количество лайков (или 1 для комментария).
    func likesAdd(
        token: String,
        type: String,
        ownerId: Int,
        itemId: Int
    ) async throws -> Int {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "item_id", value: String(itemId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/likes.add") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "likes.add type=\(type) ownerId=\(ownerId) itemId=\(itemId)")
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger?.error("VKApi", "likes.add invalid response", error: nil)
            throw NetworkError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            logger?.error("VKApi", "likes.add HTTP \(http.statusCode)", error: nil)
            throw NetworkError.httpStatus(http.statusCode, data)
        }
        if let errWrapper = try? decoder.decode(VKErrorWrapper.self, from: data) {
            let msg = errWrapper.error.errorMsg ?? "Ошибка VK \(errWrapper.error.errorCode)"
            logger?.error("VKApi", "likes.add API error \(errWrapper.error.errorCode): \(msg)", error: nil)
            throw VKApiError.apiError(code: errWrapper.error.errorCode, message: errWrapper.error.errorMsg)
        }
        do {
            let wrapper = try decoder.decode(VKResponse<VKLikesAddResponse>.self, from: data)
            let count = wrapper.response.likesCount
            logger?.info("VKApi", "likes.add ok likes=\(count)")
            return count
        } catch {
            if let body = String(data: data, encoding: .utf8) {
                logger?.error("VKApi", "likes.add decode failed, body=\(body)", error: error)
            } else {
                logger?.error("VKApi", "likes.add decode failed", error: error)
            }
            throw error
        }
    }

    // MARK: - likes.delete

    /// Убрать лайк с поста или комментария. type: "post" | "comment". Возвращает новое количество лайков.
    func likesDelete(
        token: String,
        type: String,
        ownerId: Int,
        itemId: Int
    ) async throws -> Int {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "item_id", value: String(itemId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/likes.delete") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "likes.delete type=\(type) ownerId=\(ownerId) itemId=\(itemId)")
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger?.error("VKApi", "likes.delete invalid response", error: nil)
            throw NetworkError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            logger?.error("VKApi", "likes.delete HTTP \(http.statusCode)", error: nil)
            throw NetworkError.httpStatus(http.statusCode, data)
        }
        if let errWrapper = try? decoder.decode(VKErrorWrapper.self, from: data) {
            let msg = errWrapper.error.errorMsg ?? "Ошибка VK \(errWrapper.error.errorCode)"
            logger?.error("VKApi", "likes.delete API error \(errWrapper.error.errorCode): \(msg)", error: nil)
            throw VKApiError.apiError(code: errWrapper.error.errorCode, message: errWrapper.error.errorMsg)
        }
        do {
            let wrapper = try decoder.decode(VKResponse<VKLikesAddResponse>.self, from: data)
            let count = wrapper.response.likesCount
            logger?.info("VKApi", "likes.delete ok likes=\(count)")
            return count
        } catch {
            if let body = String(data: data, encoding: .utf8) {
                logger?.error("VKApi", "likes.delete decode failed, body=\(body)", error: error)
            } else {
                logger?.error("VKApi", "likes.delete decode failed", error: error)
            }
            throw error
        }
    }

    // MARK: - wall.repost

    /// Репост записи на свою стену. object — строка "wall{owner_id}_{post_id}" (владелец исходного поста и id поста).
    /// Возвращает success, post_id на стене пользователя и reposts_count (новый счётчик репостов исходного поста).
    func wallRepost(
        token: String,
        object: String
    ) async throws -> WallRepostResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "object", value: object)
        ]
        guard var components = URLComponents(string: "\(baseURL)/wall.repost") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "wall.repost object=\(object)")
        let response = try await requestVK(WallRepostResponse.self, from: request)
        logger?.info("VKApi", "wall.repost ok success=\(response.success) repostsCount=\(response.repostsCount ?? -1)")
        return response
    }

    // MARK: - wall.delete

    /// Удалить пост со стены. owner_id — владелец стены (пользователь или -groupId), post_id — id поста.
    /// Возвращает 1 при успехе.
    func wallDelete(
        token: String,
        ownerId: Int,
        postId: Int
    ) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "post_id", value: String(postId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/wall.delete") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "wall.delete ownerId=\(ownerId) postId=\(postId)")
        let _: Int = try await requestVK(Int.self, from: request)
        logger?.info("VKApi", "wall.delete ok")
    }

    // MARK: - wall.pin / wall.unpin

    /// Закрепить пост на стене. owner_id — владелец стены, post_id — id поста. Возвращает 1 при успехе.
    func wallPin(token: String, ownerId: Int, postId: Int) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "post_id", value: String(postId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/wall.pin") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "wall.pin ownerId=\(ownerId) postId=\(postId)")
        let _: Int = try await requestVK(Int.self, from: request)
        logger?.info("VKApi", "wall.pin ok")
    }

    /// Открепить пост со стены.
    func wallUnpin(token: String, ownerId: Int, postId: Int) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "post_id", value: String(postId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/wall.unpin") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "wall.unpin ownerId=\(ownerId) postId=\(postId)")
        let _: Int = try await requestVK(Int.self, from: request)
        logger?.info("VKApi", "wall.unpin ok")
    }

    // MARK: - wall.createComment

    /// Добавить комментарий к посту. replyTo — id комментария для ответа; nil — корневой комментарий.
    /// Возвращает id созданного комментария.
    func wallCreateComment(
        token: String,
        ownerId: Int,
        postId: Int,
        message: String,
        replyTo: Int? = nil
    ) async throws -> Int {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: String(ownerId)),
            URLQueryItem(name: "post_id", value: String(postId)),
            URLQueryItem(name: "message", value: message)
        ]
        if let reply = replyTo {
            queryItems.append(URLQueryItem(name: "reply_to_comment", value: String(reply)))
        }
        guard var components = URLComponents(string: "\(baseURL)/wall.createComment") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        logger?.info("VKApi", "wall.createComment ownerId=\(ownerId) postId=\(postId) replyTo=\(replyTo ?? 0)")
        let response = try await requestVK(VKWallCreateCommentResponse.self, from: request)
        logger?.info("VKApi", "wall.createComment ok commentId=\(response.commentId)")
        return response.commentId
    }

    // MARK: - messages.getConversations

    /// Список диалогов. filter: all, unread, important и т.д. extended=1 → profiles, groups.
    func getConversations(
        token: String,
        count: Int = 20,
        offset: Int = 0,
        filter: String = "all",
        extended: Int = 1
    ) async throws -> MessagesGetConversationsResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "extended", value: String(extended))
        ]
        guard var components = URLComponents(string: "\(baseURL)/messages.getConversations") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "messages.getConversations offset=\(offset)")
        let response = try await requestVK(MessagesGetConversationsResponse.self, from: request)
        logger?.info("VKApi", "messages.getConversations ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - messages.getHistory

    /// История сообщений с peer_id (user или 2000000000+chat_id). extended=1 → profiles, groups.
    func getHistory(
        token: String,
        peerId: Int,
        count: Int = 20,
        offset: Int = 0,
        extended: Int = 1
    ) async throws -> MessagesGetHistoryResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "peer_id", value: String(peerId)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "extended", value: String(extended))
        ]
        guard var components = URLComponents(string: "\(baseURL)/messages.getHistory") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "messages.getHistory peerId=\(peerId) offset=\(offset)")
        let response = try await requestVK(MessagesGetHistoryResponse.self, from: request)
        logger?.info("VKApi", "messages.getHistory ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - messages.search

    /// Поиск по сообщениям в диалоге (peer_id). Ответ в формате как getHistory (count, items, profiles, groups).
    func searchMessages(
        token: String,
        peerId: Int,
        q: String,
        count: Int = 20,
        offset: Int = 0,
        extended: Int = 1
    ) async throws -> MessagesGetHistoryResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "peer_id", value: String(peerId)),
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "extended", value: String(extended))
        ]
        guard var components = URLComponents(string: "\(baseURL)/messages.search") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "messages.search peerId=\(peerId) q=\(q)")
        let response = try await requestVK(MessagesGetHistoryResponse.self, from: request)
        logger?.info("VKApi", "messages.search ok count=\(response.count) items=\(response.items.count)")
        return response
    }

    // MARK: - messages.send

    /// Отправить сообщение. random_id — уникальный для дедупликации. attachment — опционально, например "photo123_456". reply_to — id сообщения для ответа.
    func sendMessage(
        token: String,
        peerId: Int,
        message: String,
        randomId: Int,
        attachment: String? = nil,
        replyTo: Int? = nil
    ) async throws -> Int {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "peer_id", value: String(peerId)),
            URLQueryItem(name: "message", value: message),
            URLQueryItem(name: "random_id", value: String(randomId))
        ]
        if let att = attachment, !att.isEmpty {
            queryItems.append(URLQueryItem(name: "attachment", value: att))
        }
        if let reply = replyTo {
            queryItems.append(URLQueryItem(name: "reply_to", value: String(reply)))
        }
        guard var components = URLComponents(string: "\(baseURL)/messages.send") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        logger?.info("VKApi", "messages.send peerId=\(peerId) attachment=\(attachment ?? "nil")")
        let response = try await requestVK(MessagesSendResponse.self, from: request)
        logger?.info("VKApi", "messages.send ok messageId=\(response.messageId)")
        return response.messageId
    }

    // MARK: - messages.send (sticker)

    func sendSticker(token: String, peerId: Int, stickerId: Int) async throws -> Int {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "peer_id", value: String(peerId)),
            URLQueryItem(name: "sticker_id", value: String(stickerId)),
            URLQueryItem(name: "random_id", value: String(Int.random(in: 1...Int.max)))
        ]
        guard var components = URLComponents(string: "\(baseURL)/messages.send") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        logger?.info("VKApi", "messages.send sticker_id=\(stickerId) peerId=\(peerId)")
        let response = try await requestVK(MessagesSendResponse.self, from: request)
        logger?.info("VKApi", "messages.send sticker ok messageId=\(response.messageId)")
        return response.messageId
    }

    // MARK: - store.getStickers

    func getStickers(token: String) async throws -> [VKStickerPack] {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "type", value: "stickers"),
            URLQueryItem(name: "extended", value: "1")
        ]
        guard var components = URLComponents(string: "\(baseURL)/store.getProducts") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        logger?.info("VKApi", "store.getProducts stickers")
        let response = try await requestVK(StickerPacksResponse.self, from: request)
        logger?.info("VKApi", "store.getProducts ok items=\(response.items.count)")
        return response.items
    }

    // MARK: - messages.delete

    /// Удалить сообщение. messageIds — массив id сообщений. deleteForAll: 1 = удалить для всех (беседа).
    func deleteMessages(token: String, messageIds: [Int], deleteForAll: Bool = false) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        let idsString = messageIds.map(String.init).joined(separator: ",")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "message_ids", value: idsString),
            URLQueryItem(name: "delete_for_all", value: deleteForAll ? "1" : "0")
        ]
        guard var components = URLComponents(string: "\(baseURL)/messages.delete") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        logger?.info("VKApi", "messages.delete messageIds=\(idsString)")
        let _: [String: Int] = try await requestVK([String: Int].self, from: request)
        logger?.info("VKApi", "messages.delete ok")
    }

    // MARK: - messages.pin / messages.unpin

    /// Закрепить сообщение в диалоге. Возвращает закреплённое сообщение.
    func pinMessage(token: String, peerId: Int, messageId: Int) async throws -> VKMessage {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "peer_id", value: String(peerId)),
            URLQueryItem(name: "message_id", value: String(messageId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/messages.pin") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        logger?.info("VKApi", "messages.pin peerId=\(peerId) messageId=\(messageId)")
        return try await requestVK(VKMessage.self, from: request)
    }

    /// Открепить закреплённое сообщение в диалоге.
    func unpinMessage(token: String, peerId: Int) async throws {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "peer_id", value: String(peerId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/messages.unpin") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        logger?.info("VKApi", "messages.unpin peerId=\(peerId)")
        let _: Int = try await requestVK(Int.self, from: request)
        logger?.info("VKApi", "messages.unpin ok")
    }

    // MARK: - photos.getMessagesUploadServer / photos.saveMessagesPhoto (фото в личку)

    /// Загрузить фото на upload_url для сообщений. Проверяет HTTP-статус и логирует тело ответа при ошибке.
    func uploadMessagesPhotoToServer(uploadUrl: String, imageData: Data) async throws -> (server: String, hash: String, photo: String) {
        guard let url = URL(string: uploadUrl) else { throw VKApiError.invalidURL }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, response) = try await network.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let preview = String(data: data, encoding: .utf8).map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 } ?? "nil"
            logger?.error("VKApi", "uploadMessagesPhoto HTTP \(http.statusCode): \(preview)")
            throw VKApiError.apiError(code: http.statusCode, message: "Ошибка загрузки фото (\(http.statusCode))")
        }
        do {
            let result = try decoder.decode(OwnerPhotoUploadResult.self, from: data)
            guard let server = result.server, let hash = result.hash, let photo = result.photo else {
                throw VKApiError.apiError(code: -1, message: "Некорректный ответ загрузки фото")
            }
            return (server, hash, photo)
        } catch {
            let preview = String(data: data, encoding: .utf8).map { $0.count > 500 ? String($0.prefix(500)) + "…" : $0 } ?? "nil"
            logger?.error("VKApi", "uploadMessagesPhoto decode failed: \(preview)", error: error)
            throw error
        }
    }

    /// URL для загрузки фото в диалог (peer_id — собеседник или беседа).
    func getMessagesUploadServer(token: String, peerId: Int) async throws -> String {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "peer_id", value: String(peerId))
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.getMessagesUploadServer") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let response = try await requestVK(MessagesUploadServerResponse.self, from: request)
        guard !response.uploadUrl.isEmpty else { throw VKApiError.apiError(code: -1, message: "Пустой upload_url") }
        return response.uploadUrl
    }

    /// Сохранить загруженное фото для сообщений. Параметры — из ответа POST на upload_url. Возвращает первый фото (owner_id, id) для attachment.
    func saveMessagesPhoto(token: String, server: String, hash: String, photo: String) async throws -> SavedMessagesPhotoItem {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "server", value: server),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "photo", value: photo)
        ]
        guard var components = URLComponents(string: "\(baseURL)/photos.saveMessagesPhoto") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let list: [SavedMessagesPhotoItem] = try await requestVK([SavedMessagesPhotoItem].self, from: request)
        guard let first = list.first else { throw VKApiError.apiError(code: -1, message: "Нет фото в ответе") }
        return first
    }

    // MARK: - account.getCounters

    func getAccountCounters(token: String) async throws -> AccountCounters {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "filter", value: "messages")
        ]
        guard var components = URLComponents(string: "\(baseURL)/account.getCounters") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await requestVK(AccountCounters.self, from: request)
    }

    // MARK: - audio.get

    func getAudio(token: String, ownerId: Int, offset: Int = 0, count: Int = 100) async throws -> AudioGetResponse {
        guard !token.isEmpty else { throw VKApiError.missingToken }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "owner_id", value: "\(ownerId)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "count", value: "\(count)")
        ]
        guard var components = URLComponents(string: "\(baseURL)/audio.get") else { throw VKApiError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw VKApiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("KateMobile/52.1 (Android 5.0; Samsung SM-G900F; Build/LRX21T; ru_RU)", forHTTPHeaderField: "User-Agent")
        logger?.info("VKApi", "audio.get ownerId=\(ownerId) offset=\(offset)")
        let response = try await requestVK(AudioGetResponse.self, from: request)
        logger?.info("VKApi", "audio.get ok count=\(response.count) items=\(response.items.count)")
        return response
    }
}
