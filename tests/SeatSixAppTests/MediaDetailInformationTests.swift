import XCTest
import SeatSixCore
@testable import SeatSixApp

final class MediaDetailInformationTests: XCTestCase {
    func testRealCreditsAndStreamPropertiesFollowChosenVersion() throws {
        let json = #"""
        {"Id":"movie","Type":"Movie","PremiereDate":"2020-02-29T00:00:00Z","OfficialRating":"PG",
        "People":[{"Id":"actorA","PrimaryImageTag":"portrait-v2","Name":"Alpha","Type":"Actor","Role":"Lead"},{"Id":"../other","PrimaryImageTag":"x","Name":"Beta","Type":"Director"},null,{"Name":17}],
        "MediaStreams":[{"Type":"Audio","Codec":"old"}],
        "MediaSources":[{"Id":"cut-a","Size":987654,"MediaStreams":[{"Type":"Video","Codec":"h264","Width":1920,"Height":1080,"RealFrameRate":23.976,"AspectRatio":"16:9","BitDepth":10},{"Type":"Audio","Codec":"aac","Channels":2,"SampleRate":48000},{"Type":"Subtitle","Codec":"srt","IsDefault":true}]},{"Id":"cut-b","Size":"unavailable"}]}
        """#
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertNotNil(item.premiereDate)
        XCTAssertEqual(item.officialRating, "PG")
        XCTAssertEqual(item.people.compactMap(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(item.people[0].portraitSource, MediaArtworkSource(itemID: "actorA", type: .primary, tag: "portrait-v2"))
        XCTAssertNil(item.people[1].portraitSource)
        XCTAssertEqual(item.people.compactMap(MediaDetailInformation.creditRole), ["Lead", "导演"])
        XCTAssertTrue(MediaDetailInformation.streams(item: item, source: nil).isEmpty)
        XCTAssertNil(item.mediaSources[1].size)
        XCTAssertTrue(MediaDetailInformation.streams(item: item, source: item.mediaSources[1]).isEmpty)
        var anotherSource = item.mediaSources[0]
        anotherSource.id = "a-cut-from-another-title"
        XCTAssertTrue(MediaDetailInformation.streams(item: item, source: anotherSource).isEmpty)
        XCTAssertEqual(item.mediaSources[0].size, 987654)
        let tracks = MediaDetailInformation.streams(item: item, source: item.mediaSources[0])
        XCTAssertEqual(tracks.compactMap(MediaDetailInformation.kind), ["视频", "音频", "字幕"])
        XCTAssertEqual(MediaDetailInformation.fields(tracks[0]).first { $0.label == "分辨率" }?.value, "1920 × 1080")
        XCTAssertEqual(MediaDetailInformation.fields(tracks[1]).first { $0.label == "采样率" }?.value, "48000 Hz")
        XCTAssertEqual(MediaDetailInformation.fields(tracks[2]).first { $0.label == "默认" }?.value, "是")
    }
}
