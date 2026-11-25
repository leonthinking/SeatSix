import Foundation

public enum ServerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case emby, jellyfin
    public var id: String { rawValue }
    public var name: String { self == .emby ? "Emby" : "Jellyfin" }
}

public struct ServerConnection: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ServerKind
    public var name: String
    public var baseURL: URL
    public var serverID: String
    public var userID: String
    public var username: String
    public var libraryIDs: [String]
    public var compatibilityMode: Bool
    public var certificatePin: CertificatePin?
    public init(id: UUID = UUID(), kind: ServerKind, name: String, baseURL: URL, serverID: String, userID: String, username: String, libraryIDs: [String] = [], compatibilityMode: Bool = false, certificatePin: CertificatePin? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.baseURL = baseURL
        self.serverID = serverID; self.userID = userID; self.username = username; self.libraryIDs = libraryIDs
        self.compatibilityMode = compatibilityMode
        self.certificatePin = certificatePin
    }
    enum CodingKeys: String, CodingKey { case id, kind, name, baseURL, serverID, userID, username, libraryIDs, compatibilityMode, certificatePin }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(ServerKind.self, forKey: .kind)
        name = try values.decode(String.self, forKey: .name)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        serverID = try values.decode(String.self, forKey: .serverID)
        userID = try values.decode(String.self, forKey: .userID)
        username = try values.decode(String.self, forKey: .username)
        libraryIDs = try values.decodeIfPresent([String].self, forKey: .libraryIDs) ?? []
        compatibilityMode = try values.decodeIfPresent(Bool.self, forKey: .compatibilityMode) ?? false
        certificatePin = try values.decodeIfPresent(CertificatePin.self, forKey: .certificatePin)
    }
}

public struct AuthenticatedServer: Sendable {
    public var connection: ServerConnection
    public var token: String
    public init(connection: ServerConnection, token: String) { self.connection = connection; self.token = token }
}

public struct MediaIdentity: Codable, Hashable, Sendable {
    public var serverID: String
    public var userID: String
    public var itemID: String
    public init(serverID: String, userID: String, itemID: String) { self.serverID = serverID; self.userID = userID; self.itemID = itemID }
}

public struct MediaLibrary: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var collectionType: String?
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", collectionType = "CollectionType" }
    public init(id: String, name: String, collectionType: String? = nil) { self.id = id; self.name = name; self.collectionType = collectionType }
}

public struct MediaUserData: Decodable, Equatable, Sendable {
    public var playbackPositionTicks: Int64
    public var played: Bool
    public var isFavorite: Bool
    /// A missing flag still displays as false, but cannot confirm a server mutation.
    public private(set) var playedKnown: Bool
    public private(set) var isFavoriteKnown: Bool
    public private(set) var playbackPositionKnown: Bool
    enum CodingKeys: String, CodingKey { case playbackPositionTicks = "PlaybackPositionTicks", played = "Played", isFavorite = "IsFavorite" }
    public init(playbackPositionTicks: Int64 = 0, played: Bool = false, isFavorite: Bool = false, playedKnown: Bool = true, isFavoriteKnown: Bool = true, playbackPositionKnown: Bool = true) {
        self.playbackPositionTicks = playbackPositionTicks; self.played = played; self.isFavorite = isFavorite
        self.playedKnown = playedKnown; self.isFavoriteKnown = isFavoriteKnown
        self.playbackPositionKnown = playbackPositionKnown
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPosition = try values.decodeIfPresent(Int64.self, forKey: .playbackPositionTicks)
        playbackPositionTicks = decodedPosition ?? 0; playbackPositionKnown = decodedPosition != nil
        let decodedPlayed = try values.decodeIfPresent(Bool.self, forKey: .played)
        let decodedFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite)
        played = decodedPlayed ?? false; playedKnown = decodedPlayed != nil
        isFavorite = decodedFavorite ?? false; isFavoriteKnown = decodedFavorite != nil
    }
}

public struct MediaStream: Decodable, Equatable, Sendable {
    public var type: String?
    public var codec: String?
    public var index: Int?
    public var width: Int?
    public var height: Int?
    public var language: String?
    public var displayTitle: String?
    public var bitDepth: Int?
    public var profile: String?
    public var title: String?
    public var isExternal: Bool?
    public var isTextSubtitleStream: Bool?
    public var isDefault: Bool?
    public var isForced: Bool?
    public var deliveryURL: String?
    public var aspectRatio: String?
    public var frameRate: Double?
    public var averageFrameRate: Double?
    public var channels: Int?
    public var channelLayout: String?
    public var sampleRate: Int?
    public var bitRate: Int?
    public var colorSpace: String?
    enum CodingKeys: String, CodingKey {
        case aspectRatio = "AspectRatio", frameRate = "RealFrameRate", averageFrameRate = "AverageFrameRate", channels = "Channels", channelLayout = "ChannelLayout", sampleRate = "SampleRate", bitRate = "BitRate", colorSpace = "ColorSpace"
        case type = "Type", codec = "Codec", index = "Index", width = "Width", height = "Height", language = "Language", displayTitle = "DisplayTitle", bitDepth = "BitDepth", profile = "Profile", title = "Title", isExternal = "IsExternal", isTextSubtitleStream = "IsTextSubtitleStream", isDefault = "IsDefault", isForced = "IsForced", deliveryURL = "DeliveryUrl" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        codec = try values.decodeIfPresent(String.self, forKey: .codec)
        index = try values.decodeIfPresent(Int.self, forKey: .index)
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        displayTitle = try values.decodeIfPresent(String.self, forKey: .displayTitle)
        bitDepth = try values.decodeIfPresent(Int.self, forKey: .bitDepth)
        profile = try values.decodeIfPresent(String.self, forKey: .profile)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        isExternal = try values.decodeIfPresent(Bool.self, forKey: .isExternal)
        isTextSubtitleStream = try values.decodeIfPresent(Bool.self, forKey: .isTextSubtitleStream)
        isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault)
        isForced = try values.decodeIfPresent(Bool.self, forKey: .isForced)
        deliveryURL = try values.decodeIfPresent(String.self, forKey: .deliveryURL)
        aspectRatio = try? values.decode(String.self, forKey: .aspectRatio)
        frameRate = try? values.decode(Double.self, forKey: .frameRate)
        averageFrameRate = try? values.decode(Double.self, forKey: .averageFrameRate)
        channels = try? values.decode(Int.self, forKey: .channels)
        channelLayout = try? values.decode(String.self, forKey: .channelLayout)
        sampleRate = try? values.decode(Int.self, forKey: .sampleRate)
        bitRate = try? values.decode(Int.self, forKey: .bitRate)
        colorSpace = try? values.decode(String.self, forKey: .colorSpace)
    }
}

public struct MediaSource: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var container: String?
    public var path: String?
    public var protocolName: String?
    public var runTimeTicks: Int64?
    public var requiresOpening: Bool?
    public var supportsDirectPlay: Bool?
    public var supportsDirectStream: Bool?
    public var supportsTranscoding: Bool?
    public var directStreamURL: String?
    public var transcodingURL: String?
    public var mediaStreams: [MediaStream]?
    public var size: Int64?
    enum CodingKeys: String, CodingKey {
        case size = "Size"
        case id = "Id", name = "Name", container = "Container", path = "Path", protocolName = "Protocol", runTimeTicks = "RunTimeTicks", requiresOpening = "RequiresOpening", supportsDirectPlay = "SupportsDirectPlay", supportsDirectStream = "SupportsDirectStream", supportsTranscoding = "SupportsTranscoding", directStreamURL = "DirectStreamUrl", transcodingURL = "TranscodingUrl", mediaStreams = "MediaStreams"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        container = try values.decodeIfPresent(String.self, forKey: .container)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        protocolName = try values.decodeIfPresent(String.self, forKey: .protocolName)
        runTimeTicks = try values.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        requiresOpening = try values.decodeIfPresent(Bool.self, forKey: .requiresOpening)
        supportsDirectPlay = try values.decodeIfPresent(Bool.self, forKey: .supportsDirectPlay)
        supportsDirectStream = try values.decodeIfPresent(Bool.self, forKey: .supportsDirectStream)
        supportsTranscoding = try values.decodeIfPresent(Bool.self, forKey: .supportsTranscoding)
        directStreamURL = try values.decodeIfPresent(String.self, forKey: .directStreamURL)
        transcodingURL = try values.decodeIfPresent(String.self, forKey: .transcodingURL)
        mediaStreams = try values.decodeIfPresent([MediaStream].self, forKey: .mediaStreams)
        size = try? values.decode(Int64.self, forKey: .size)
    }
}

public struct MediaCredit: Decodable, Equatable, Sendable {
    public let name: String?
    public let role: String?
    public let type: String?

    public let portraitSource: MediaArtworkSource?

    enum CodingKeys: String, CodingKey {
        case name = "Name", role = "Role", type = "Type", id = "Id", portraitTag = "PrimaryImageTag"
    }
    public init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        name = try? fields?.decode(String.self, forKey: .name)
        role = try? fields?.decode(String.self, forKey: .role)
        type = try? fields?.decode(String.self, forKey: .type)
        if let id = try? fields?.decode(String.self, forKey: .id),
           let tag = try? fields?.decode(String.self, forKey: .portraitTag) {
            let portrait = MediaArtworkSource(itemID: id, type: .primary, tag: tag)
            portraitSource = portrait.isValid ? portrait : nil
        } else {
            portraitSource = nil
        }
    }
}

public struct MediaItem: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var overview: String?
    public var productionYear: Int?
    public var premiereDate: Date?
    public var officialRating: String?
    public var people: [MediaCredit]
    public var mediaStreams: [MediaStream]
    public var communityRating: Double?
    /// The server's library-addition timestamp, independent of the release year.
    public var dateCreated: Date?
    public var genres: [String]
    public var sortName: String?
    public var runTimeTicks: Int64?
    public var userData: MediaUserData
    public var mediaSources: [MediaSource]
    public var imageTags: [String: String]
    public var backdropImageTags: [String]
    public var primaryImageAspectRatio: Double?
    public var parentBackdropItemID: String?
    public var parentBackdropImageTags: [String]
    public var parentThumbItemID: String?
    public var parentThumbImageTag: String?
    public var seriesThumbImageTag: String?
    public var seriesName: String?
    public var seriesID: String?
    public var seasonID: String?
    public var parentID: String?
    public var indexNumber: Int?
    public var indexNumberEnd: Int?
    public var parentIndexNumber: Int?
    public var isPlayable: Bool { ["Movie", "Episode", "Video"].contains(type) }
    public var durationSeconds: Double { Double(runTimeTicks ?? 0) / 10_000_000 }
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", overview = "Overview", productionYear = "ProductionYear", runTimeTicks = "RunTimeTicks", userData = "UserData", mediaSources = "MediaSources", imageTags = "ImageTags", seriesName = "SeriesName", seriesID = "SeriesId", seasonID = "SeasonId", parentID = "ParentId", indexNumber = "IndexNumber", indexNumberEnd = "IndexNumberEnd", parentIndexNumber = "ParentIndexNumber"
        case premiereDate = "PremiereDate", officialRating = "OfficialRating", people = "People", mediaStreams = "MediaStreams"
        case communityRating = "CommunityRating"
        case genres = "Genres", genreItems = "GenreItems", sortName = "SortName", dateCreated = "DateCreated"
        case backdropImageTags = "BackdropImageTags", primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case parentBackdropItemID = "ParentBackdropItemId", parentBackdropImageTags = "ParentBackdropImageTags"
        case parentThumbItemID = "ParentThumbItemId", parentThumbImageTag = "ParentThumbImageTag", seriesThumbImageTag = "SeriesThumbImageTag"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "未命名影片"
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "Video"
        overview = try values.decodeIfPresent(String.self, forKey: .overview)
        productionYear = try values.decodeIfPresent(Int.self, forKey: .productionYear)
        premiereDate = (try? values.decode(String.self, forKey: .premiereDate)).flatMap(Self.creationDate)
        officialRating = try? values.decode(String.self, forKey: .officialRating)
        people = ((try? values.decode([MediaCredit].self, forKey: .people)) ?? []).filter {
            $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        mediaStreams = (try? values.decode([MediaStream].self, forKey: .mediaStreams)) ?? []
        if let rating = try? values.decode(Double.self, forKey: .communityRating), (0...10).contains(rating) {
            communityRating = rating
        }
        // Optional metadata must not make an otherwise usable catalog fail to load.
        // Servers use both RFC 3339 seconds and .NET-style fractional seconds.
        let created = try? values.decodeIfPresent(String.self, forKey: .dateCreated)
        dateCreated = created.flatMap(Self.creationDate)
        let genreNames = (try values.decodeIfPresent([String].self, forKey: .genres) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        genres = genreNames.isEmpty ? (try values.decodeIfPresent([GenreName].self, forKey: .genreItems) ?? []).compactMap(\.name).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } : genreNames
        sortName = try values.decodeIfPresent(String.self, forKey: .sortName)
        runTimeTicks = try values.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        userData = try values.decodeIfPresent(MediaUserData.self, forKey: .userData) ?? MediaUserData(playedKnown: false, isFavoriteKnown: false, playbackPositionKnown: false)
        mediaSources = try values.decodeIfPresent([MediaSource].self, forKey: .mediaSources) ?? []
        // Optional artwork metadata may be absent or malformed on compatible servers.
        // Keep array positions so a valid later backdrop retains its server image index.
        imageTags = ((try? values.decode([String: ArtworkTag].self, forKey: .imageTags)) ?? [:]).mapValues(\.value)
        backdropImageTags = ((try? values.decode([ArtworkTag].self, forKey: .backdropImageTags)) ?? []).map(\.value)
        primaryImageAspectRatio = try? values.decode(Double.self, forKey: .primaryImageAspectRatio)
        parentBackdropItemID = try? values.decode(String.self, forKey: .parentBackdropItemID)
        parentBackdropImageTags = ((try? values.decode([ArtworkTag].self, forKey: .parentBackdropImageTags)) ?? []).map(\.value)
        parentThumbItemID = try? values.decode(String.self, forKey: .parentThumbItemID)
        parentThumbImageTag = try? values.decode(String.self, forKey: .parentThumbImageTag)
        seriesThumbImageTag = try? values.decode(String.self, forKey: .seriesThumbImageTag)
        seriesName = try values.decodeIfPresent(String.self, forKey: .seriesName)
        seriesID = try values.decodeIfPresent(String.self, forKey: .seriesID)
        seasonID = try values.decodeIfPresent(String.self, forKey: .seasonID)
        parentID = try values.decodeIfPresent(String.self, forKey: .parentID)
        indexNumber = try values.decodeIfPresent(Int.self, forKey: .indexNumber)
        indexNumberEnd = try values.decodeIfPresent(Int.self, forKey: .indexNumberEnd)
        parentIndexNumber = try values.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
    }

    private struct ArtworkTag: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            value = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        }
    }

    private struct GenreName: Decodable {
        let name: String?
        enum CodingKeys: String, CodingKey { case name = "Name" }
    }

    private static let creationDatePattern = try! NSRegularExpression(pattern:
        #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\z"#)

    private static func creationDate(_ value: String) -> Date? {
        guard creationDatePattern.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)) != nil else { return nil }
        // ISO8601FormatStyle accepts a valid prefix and normalizes dates such as
        // February 30. Reject both so bad metadata cannot rank as a new addition.
        let parts = value.prefix(19).split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count == 6,
              DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0),
                             year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5]).isValidDate else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

public struct MediaPage: Decodable, Sendable {
    public var items: [MediaItem]
    public var totalRecordCount: Int
    public var startIndex: Int
    enum CodingKeys: String, CodingKey { case items = "Items", totalRecordCount = "TotalRecordCount", startIndex = "StartIndex" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([MediaItem].self, forKey: .items) ?? []
        totalRecordCount = try values.decodeIfPresent(Int.self, forKey: .totalRecordCount) ?? items.count
        startIndex = try values.decodeIfPresent(Int.self, forKey: .startIndex) ?? 0
    }
}

public enum PlaybackMode: String, CaseIterable, Identifiable, Sendable { case automatic, compatible; public var id: String { rawValue } }
public enum PlaybackCapability: Equatable, Sendable { case avFoundation, localDecoder }
public enum PlaybackMethod: String, Codable, Sendable { case directPlay = "DirectPlay", transcode = "Transcode" }

/// An external text subtitle belonging to the source selected by playback negotiation.
/// Requests and authentication remain inside MediaServerClient, never in the decoder.
public struct ServerSubtitle: Identifiable, Equatable, Sendable {
    public let itemID: String
    public let mediaSourceID: String
    public let streamIndex: Int
    public let title: String
    public let language: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let fileExtension: String
    public var id: String { "\(itemID):\(mediaSourceID):\(streamIndex)" }
    let connectionID: UUID
    let serverID: String
    let userID: String
    let requestURL: URL
}

public struct DownloadedSubtitle: Sendable {
    public let data: Data
    public let fileExtension: String
}

public struct PlaybackPlan: Sendable {
    public var itemID: String
    public var mediaSourceID: String
    public var playSessionID: String
    public var url: URL
    public var method: PlaybackMethod
    public var resumeTicks: Int64
    public var runtimeTicks: Int64?
    public var externalSubtitles: [ServerSubtitle]
    public var isTranscoding: Bool { method == .transcode }
    public init(itemID: String, mediaSourceID: String, playSessionID: String, url: URL, method: PlaybackMethod, resumeTicks: Int64, runtimeTicks: Int64? = nil, externalSubtitles: [ServerSubtitle] = []) {
        self.itemID = itemID; self.mediaSourceID = mediaSourceID; self.playSessionID = playSessionID; self.url = url; self.method = method; self.resumeTicks = resumeTicks
        self.runtimeTicks = runtimeTicks
        self.externalSubtitles = externalSubtitles
    }
}

public enum MediaServerError: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress, insecureAddress, wrongServerKind, invalidResponse, unsupportedMedia, unsupportedCompatibilityMedia, unsupportedLocalMedia, externalStream, invalidScope, reportingUncertain, invalidReportingState
    case httpStatus(Int)
    case network
    case subtitleTooLarge
    case certificate(CertificateTrustError)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入完整的 HTTP 或 HTTPS 服务器地址；地址不能包含账户、查询参数或锚点。"
        case .insecureAddress: return "公网连接必须使用 HTTPS。局域网 HTTP 连接需勾选允许明文连接。"
        case .wrongServerKind: return "服务器类型不匹配，请检查 Emby / Jellyfin 选择。"
        case .invalidResponse: return "服务器返回了无法识别的数据。"
        case .unsupportedMedia: return "此资源无法使用当前播放模式。请尝试兼容播放，或检查服务器转码权限。"
        case .unsupportedCompatibilityMedia: return "此 Emby 兼容服务未提供当前播放引擎可用的原始媒体资源。请检查文件格式或选择其他版本。"
        case .unsupportedLocalMedia: return "此资源无法使用本地解码播放。请检查媒体格式、原始文件访问权限，或选择其他版本；不会请求服务器转码。"
        case .externalStream: return "播放资源指向其他地址，本版本只允许当前服务器地址下的资源。"
        case .invalidScope: return "所选媒体库不在当前连接的访问范围中。"
        case .reportingUncertain: return "服务器进度同步未确认；本次播放不再自动回写，请保留本机进度。"
        case .invalidReportingState: return "播放会话状态无效。"
        case .httpStatus(401): return "登录已失效，或用户名与密码不正确。"
        case .httpStatus(403): return "当前账户没有执行此操作的权限。"
        case .httpStatus(404): return "未找到服务器接口或影片，请检查地址及媒体库。"
        case .httpStatus: return "服务器暂时无法完成请求，请稍后重试。"
        case .certificate(let error): return error.localizedDescription
        case .network: return "连接失败。请检查网络、服务器地址及 HTTPS 证书。"
        case .subtitleTooLarge: return "字幕文件超过 10 MiB，请选择较小的字幕文件。"
        }
    }
}
