import Foundation

/// Stable route identifiers shared by navigation, restoration and detail return.
enum BrowseDestination: String, CaseIterable {
    case home, favorites, library, continuing, recent, movies, series, other, servers, searchLibrary, searchServer

    var title: String {
        switch self {
        case .home: return "首页"
        case .favorites: return "收藏"
        case .library: return "媒体库"
        case .continuing: return "继续观看"
        case .recent: return "最近添加"
        case .movies: return "电影"
        case .series: return "剧集"
        case .other: return "其他"
        case .servers: return "管理服务器"
        case .searchLibrary, .searchServer: return "搜索"
        }
    }

    var isServerBrowse: Bool {
        switch self {
        case .favorites, .continuing, .recent, .movies, .series, .other, .searchServer: return true
        default: return false
        }
    }

    var isSearch: Bool { self == .searchLibrary || self == .searchServer }
    var isRestorable: Bool { self != .servers && !isSearch }
}
