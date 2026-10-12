import XCTest
import SwiftUI
import AppKit
@testable import CCode

final class SearchLayoutTests: XCTestCase {
    @MainActor func testSearchPickerDoesNotStretchHeader() {
        let store = AppStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.openSessionSearch()
        for appearance in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: SessionSearchView(store: store).font(.system(size: 14)).preferredColorScheme(appearance))
            let size = host.fittingSize
            print("Search dialog \(appearance): \(size)")
            XCTAssertEqual(size.width, 620, accuracy: 1)
            XCTAssertLessThan(size.height, 560, "The picker label must not wrap vertically and stretch the search header: \(size)")
        }
    }
}
