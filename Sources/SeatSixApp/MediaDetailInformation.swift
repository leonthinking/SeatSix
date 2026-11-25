import SwiftUI
import SeatSixCore

enum MediaDetailInformation {
    struct Field: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    static func creditRole(_ credit: MediaCredit) -> String? {
        if let role = credit.role, !role.isEmpty { return role }
        let roles = ["Actor": "演员", "Director": "导演", "Writer": "编剧", "Producer": "制片人", "Composer": "作曲"]
        return credit.type.flatMap { roles[$0] ?? $0 }
    }

    static func kind(_ stream: MediaStream) -> String? {
        ["Video": "视频", "Audio": "音频", "Subtitle": "字幕"][stream.type ?? ""]
    }

    static func fields(_ stream: MediaStream) -> [Field] {
        var fields: [Field] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            fields.append(.init(label: label, value: value))
        }
        add("标题", stream.displayTitle)
        add("内嵌标题", stream.title)
        add("语言", stream.language)
        add("编码", stream.codec?.uppercased())
        add("配置文件", stream.profile)
        if let w = stream.width, let h = stream.height, w > 0, h > 0 { add("分辨率", "\(w) × \(h)") }
        add("宽高比", stream.aspectRatio)
        if let rate = stream.frameRate ?? stream.averageFrameRate, rate.isFinite, rate > 0 {
            add("帧率", rate.formatted(.number.precision(.fractionLength(0...3))))
        }
        if let depth = stream.bitDepth, depth > 0 { add("位深度", "\(depth)") }
        add("色域", stream.colorSpace)
        add("声道布局", stream.channelLayout)
        if let count = stream.channels, count > 0 { add("声道数", "\(count)") }
        if let rate = stream.sampleRate, rate > 0 { add("采样率", "\(rate) Hz") }
        if let rate = stream.bitRate, rate > 0 { add("比特率", "\(rate) bit/s") }
        if stream.isDefault == true { add("默认", "是") }
        return fields
    }

    static func streams(item: MediaItem, source: MediaSource?) -> [MediaStream] {
        // An item-level stream list may refer to a different cut of a multi-version movie.
        if let source, !item.mediaSources.contains(where: { $0.id == source.id }) { return [] }
        let streams = source?.mediaStreams ?? (item.mediaSources.count <= 1 ? item.mediaStreams : [])
        return streams.filter { kind($0) != nil }
    }
}

private struct CreditPortrait: View {
    @ObservedObject var model: ApplicationModel
    let person: MediaCredit
    let cache: PosterCache
    @State private var image: NSImage?
    @State private var loadedKey: String?

    private var key: String {
        String(reflecting: [model.connection?.id.uuidString, model.connection?.baseURL.absoluteString,
                            model.connection?.serverID, model.connection?.userID, model.posterRevision.uuidString]
               + (person.portraitSource?.cacheComponents ?? []))
    }

    var body: some View {
        ZStack {
            if loadedKey == key, let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(String((person.name ?? "").prefix(2))).font(.headline)
            }
        }
        .frame(width: 58, height: 58)
        .background(.quaternary)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: key) {
            image = nil
            loadedKey = nil
            guard let source = person.portraitSource, let connection = model.connection,
                  let client = try? model.client(for: connection) else { return }
            let requestKey = key
            let result = await cache.load(key: requestKey, sources: [source], client: client,
                                          role: .poster, requestWidth: 132)
            guard !Task.isCancelled, key == requestKey else { return }
            image = result
            loadedKey = requestKey
        }
    }
}

struct MediaDetailInformationView: View {
    @ObservedObject var model: ApplicationModel
    @Environment(\.detailArtworkAppearance) private var appearance
    let people: [MediaCredit]
    let streams: [MediaStream]
    var awaitsCredits = false
    var awaitsStreams = false
    var portraitCache = PosterCache.shared

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("演职人员").font(.title3.bold()).shelfRefreshRegion()
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                            VStack(spacing: 5) {
                                CreditPortrait(model: model, person: person, cache: portraitCache)
                                    .shelfRefreshRegion(cornerRadius: 29)
                                Text(person.name ?? "").lineLimit(2).shelfRefreshRegion()
                                if let role = MediaDetailInformation.creditRole(person) {
                                    Text(role).font(.caption).foregroundStyle(appearance.secondaryText).lineLimit(2).shelfRefreshRegion()
                                }
                            }.frame(width: 94).accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        } else if awaitsCredits {
            VStack(alignment: .leading, spacing: 12) {
                DetailPlaceholderLine(width: 80, font: .title3.bold())
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(0..<8, id: \.self) { _ in
                            VStack(spacing: 5) {
                                Circle().fill(appearance.placeholderFill).frame(width: 58, height: 58)
                                    .shelfRefreshRegion(cornerRadius: 29)
                                DetailPlaceholderLine(width: 66, font: .body)
                                DetailPlaceholderLine(width: 40, font: .caption)
                            }.frame(width: 94)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel("正在读取演职人员")
        }
        if !streams.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("音视频字幕信息").font(.title3.bold()).shelfRefreshRegion()
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(streams.enumerated()), id: \.offset) { _, stream in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(MediaDetailInformation.kind(stream) ?? "").font(.headline)
                                ForEach(MediaDetailInformation.fields(stream)) { field in
                                    LabeledContent(field.label, value: field.value)
                                        .font(.caption).foregroundStyle(appearance.secondaryText).textSelection(.enabled)
                                }
                            }.padding(14).frame(width: 250, alignment: .leading)
                                .background(appearance.panelFill, in: RoundedRectangle(cornerRadius: 10))
                                .shelfRefreshRegion(cornerRadius: 10, isBackdrop: true)
                        }
                    }
                }
            }
        } else if awaitsStreams {
            VStack(alignment: .leading, spacing: 12) {
                DetailPlaceholderLine(width: 110, font: .title3.bold())
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                DetailPlaceholderLine(width: 60, font: .headline)
                                DetailPlaceholderLine(width: 160, font: .caption)
                                DetailPlaceholderLine(width: 120, font: .caption)
                            }.padding(14).frame(width: 250, alignment: .leading)
                                .background(appearance.panelFill, in: RoundedRectangle(cornerRadius: 10))
                                .shelfRefreshRegion(cornerRadius: 10, isBackdrop: true)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel("正在读取媒体流信息")
        }
    }
}
