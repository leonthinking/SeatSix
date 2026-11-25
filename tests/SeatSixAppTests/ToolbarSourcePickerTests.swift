import AppKit
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

final class ToolbarSourcePickerTests: XCTestCase {
    @MainActor
    func testSourceCapsuleFitsItsCurrentNameWithoutDrawingASecondBezel() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ApplicationModel(storage: try ApplicationStorage(directory: directory))
        let short = ServerConnection(kind: .emby, name: "我的 NAS", baseURL: try XCTUnwrap(URL(string: "https://fixture.invalid")),
                                     serverID: "short", userID: "viewer", username: "viewer", libraryIDs: [])
        var long = short
        long.id = UUID()
        long.name = String(repeating: "很长的媒体服务器名称", count: 8)
        model.saved.connections = [short, long]

        func measure(_ selected: UUID) throws -> CGSize {
            model.saved.selectedID = selected
            let host = NSHostingView(rootView: ToolbarSourcePicker(model: model, maxWidth: 150).fixedSize())
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            func popups(in view: NSView) -> [NSPopUpButton] {
                if let popup = view as? NSPopUpButton { return [popup] }
                return view.subviews.flatMap { popups(in: $0) }
            }
            let controls = popups(in: host)
            XCTAssertEqual(controls.count, 1)
            let popup = try XCTUnwrap(controls.first)
            XCTAssertEqual(popup.selectedItem?.representedObject as? UUID, selected)
            if #available(macOS 26, *) {
                XCTAssertFalse(popup.isBordered, "Only the shared toolbar glass should draw the capsule")
                XCTAssertEqual(popup.alignment, .center, "Center the native name in the space beside its arrow")
            } else {
                XCTAssertTrue(popup.isBordered, "Older systems use the native rounded pop-up bezel")
            }
            return host.fittingSize
        }

        let compact = try measure(short.id)
        let capped = try measure(long.id)
        XCTAssertLessThan(compact.width, 120, "An unselected long server name must not leave a wide empty capsule")
        XCTAssertEqual(capped.width, 150, accuracy: 1)
        XCTAssertEqual(compact.height, 36, accuracy: 1)
        XCTAssertEqual(compact.height, capped.height, accuracy: 1)
    }
}
