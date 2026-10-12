import XCTest
import AppKit
import WebKit
import CCodeCore
@testable import CCode

final class BrowserWorkflowTests: XCTestCase {
    @MainActor func testRealDOMClickFillAndSelectionUseTheOwnedTab() async throws {
        let browser = BrowserWorkspace()
        let tab = try browser.open(URL(string: "http://127.0.0.1:38931/")!)
        browser.allowAgent(on: tab.id)
        addTeardownBlock { await browser.close() }
        try await load(tab, html: """
        <h1>Preview</h1><button onclick="document.querySelector('h1').textContent='Clicked'">Change title</button>
        <input aria-label="Name" oninput="document.querySelector('h1').textContent=this.value">
        """)
        let dom = try await payload(browser, "browser_inspect", ["tabId": .string(tab.id.uuidString)])
        XCTAssertTrue(dom["text"].string.contains("Preview"))
        let button = try XCTUnwrap(dom["elements"].array.first { $0["tag"].string == "button" })
        let input = try XCTUnwrap(dom["elements"].array.first { $0["tag"].string == "input" })
        _ = try await payload(browser, "browser_click", ["tabId": .string(tab.id.uuidString), "elementId": button["id"]])
        let title = try await tab.webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        XCTAssertEqual(title, "Clicked")
        _ = try await payload(browser, "browser_fill", ["tabId": .string(tab.id.uuidString), "elementId": input["id"], "value": "Literal 'quotes' $()"])
        let filled = try await tab.webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        XCTAssertEqual(filled, "Literal 'quotes' $()")
        let selection = try await payload(browser, "browser_select", ["tabId": .string(tab.id.uuidString), "elementId": button["id"]])
        XCTAssertEqual(selection["tag"].string, "button")
        XCTAssertTrue(tab.selectedContext?.contains("Change title") == true)
    }

    @MainActor func testUngrantAndAuthenticationPagesRefuseAgentInspection() async throws {
        let browser = BrowserWorkspace(), url = URL(string: "http://127.0.0.1:38931/")!
        let tab = try browser.open(url)
        addTeardownBlock { await browser.close() }
        try await load(tab, html: "<h1>Ungrant</h1>")
        do { _ = try await browser.callTool("browser_inspect", arguments: ["tabId": .string(tab.id.uuidString)]); XCTFail("Ungrant inspected") } catch {}
        browser.allowAgent(on: tab.id)
        try await load(tab, html: "<input type='password' value='do-not-inspect'><h1>Private</h1>")
        do { _ = try await browser.callTool("browser_inspect", arguments: ["tabId": .string(tab.id.uuidString)]); XCTFail("Password page inspected") } catch {}
        do { _ = try await browser.callTool("browser_screenshot", arguments: ["tabId": .string(tab.id.uuidString)]); XCTFail("Password page captured") } catch {}
        let login = try browser.open(url.appendingPathComponent("login"), login: true)
        browser.allowAgent(on: login.id)
        try await load(login, html: "<h1>Login</h1>")
        do { _ = try await browser.callTool("browser_inspect", arguments: ["tabId": .string(login.id.uuidString)]); XCTFail("Login tab inspected") } catch {}
        XCTAssertFalse(login.webView.configuration.websiteDataStore === tab.webView.configuration.websiteDataStore)
    }

    @MainActor func testStaleElementAndForeignOrClosedTabRefuse() async throws {
        let browser = BrowserWorkspace(), other = BrowserWorkspace()
        addTeardownBlock { await browser.close(); await other.close() }
        let tab = try browser.open(URL(string: "http://127.0.0.1:38931/")!), foreign = try other.open(URL(string: "http://127.0.0.1:38932/")!)
        browser.allowAgent(on: tab.id)
        try await load(tab, html: "<button>Old</button>")
        let dom = try await payload(browser, "browser_inspect", ["tabId": .string(tab.id.uuidString)])
        let element = try XCTUnwrap(dom["elements"].array.first)
        try await load(tab, html: "<button onclick=\"document.body.dataset.clicked='yes'\">New</button>")
        do { _ = try await browser.callTool("browser_click", arguments: ["tabId": .string(tab.id.uuidString), "elementId": element["id"]]); XCTFail("Stale element clicked") } catch {}
        let clicked = try await tab.webView.evaluateJavaScript("document.body.dataset.clicked || 'no'") as? String
        XCTAssertEqual(clicked, "no")
        do { _ = try await browser.callTool("browser_inspect", arguments: ["tabId": .string(foreign.id.uuidString)]); XCTFail("Foreign tab inspected") } catch {}
        browser.closeTab(tab.id)
        do { _ = try await browser.callTool("browser_inspect", arguments: ["tabId": .string(tab.id.uuidString)]); XCTFail("Closed tab inspected") } catch {}
        XCTAssertTrue(browser.tabs.isEmpty); XCTAssertNil(tab.webView.navigationDelegate)
    }

    @MainActor func testConsoleDiagnosticsAreRealAndBounded() async throws {
        let browser = BrowserWorkspace(), tab = try browser.open(URL(string: "http://127.0.0.1:38931/")!)
        browser.allowAgent(on: tab.id); addTeardownBlock { await browser.close() }
        try await load(tab, html: "<h1>Diagnostics</h1>")
        _ = try await tab.webView.evaluateJavaScript("for(let i=0;i<150;i++) console.log('event '+i)")
        try await Task.sleep(for: .milliseconds(100))
        let diagnostics = try await payload(browser, "browser_diagnostics", ["tabId": .string(tab.id.uuidString)])
        XCTAssertEqual(diagnostics["console"].array.count, 100)
        XCTAssertTrue(diagnostics["console"].array.last?["text"].string.contains("event 149") == true)
    }

    @MainActor func testSPARoutingIntoAuthenticationRevokesInspection() async throws {
        let browser = BrowserWorkspace(), tab = try browser.open(URL(string: "http://127.0.0.1:38931/")!)
        browser.allowAgent(on: tab.id); addTeardownBlock { await browser.close() }
        try await load(tab, html: "<h1>Public</h1>")
        _ = try await payload(browser, "browser_inspect", ["tabId": .string(tab.id.uuidString)])
        _ = try await tab.webView.evaluateJavaScript("history.pushState({},'', '/login'); document.body.innerHTML='<h1>Private authentication step</h1>'")
        do { _ = try await browser.callTool("browser_inspect", arguments: ["tabId": .string(tab.id.uuidString)]); XCTFail("SPA authentication route inspected using stale URL") } catch {}
    }

    @MainActor func testExplicitLoginProfileHandoffKeepsLoginTabManual() async throws {
        let browser = BrowserWorkspace(), login = try browser.open(URL(string: "http://127.0.0.1:38931/app")!, login: true)
        addTeardownBlock { await browser.close() }
        try await load(login, html: "<h1>Signed in preview</h1>")
        let preview = try await browser.previewFromLogin(login.id)
        XCTAssertTrue(login.manualLogin); XCTAssertFalse(preview.manualLogin)
        XCTAssertTrue(login.webView.configuration.websiteDataStore === preview.webView.configuration.websiteDataStore)
        XCTAssertTrue(browser.isAllowed(preview.url))
        try await load(preview, html: "<h1>Signed in preview</h1>")
        let dom = try await payload(browser, "browser_inspect", ["tabId": .string(preview.id.uuidString)])
        XCTAssertTrue(dom["text"].string.contains("Signed in preview"))
        do { _ = try await browser.callTool("browser_inspect", arguments: ["tabId": .string(login.id.uuidString)]); XCTFail("Original login tab became inspectable") } catch {}
    }

    @MainActor func testScreenshotContainsRenderedFixturePixels() async throws {
        let browser = BrowserWorkspace(), tab = try browser.open(URL(string: "http://127.0.0.1:38931/")!)
        browser.allowAgent(on: tab.id); addTeardownBlock { await browser.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tab.webView; defer { window.contentView = nil }
        try await load(tab, html: "<style>body{margin:0;background:#ee00ee;min-height:100vh}</style><h1>Rendered fixture</h1>")
        tab.webView.layoutSubtreeIfNeeded()
        let result = try await browser.callTool("browser_screenshot", arguments: ["tabId": .string(tab.id.uuidString)])
        let image = try XCTUnwrap(result["content"].array.first)
        XCTAssertEqual(image["mimeType"].string, "image/png")
        let bytes = try XCTUnwrap(Data(base64Encoded: image["data"].string)), bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
        let css = try await tab.webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        XCTAssertEqual(css as? String, "rgb(238, 0, 238)")
        // NSBitmapImageRep.colorAt assigns a calibrated space rather than the PNG's
        // raw sRGB bytes. Compare the encoded pixels, independently of that conversion.
        XCTAssertEqual(bitmap.bitsPerSample, 8); XCTAssertFalse(bitmap.isPlanar)
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        let offset = bitmap.pixelsHigh / 2 * bitmap.bytesPerRow + bitmap.pixelsWide / 2 * bitmap.samplesPerPixel + (bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0)
        XCTAssertEqual(pixels[offset], 238); XCTAssertEqual(pixels[offset + 1], 0); XCTAssertEqual(pixels[offset + 2], 238)
        try bytes.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/browser-fixture-screenshot.png"))
    }

    @MainActor private func load(_ tab: BrowserTab, html: String) async throws {
        tab.webView.loadHTMLString(html, baseURL: tab.url)
        let until = ContinuousClock.now + .seconds(5)
        repeat { try await Task.sleep(for: .milliseconds(20)) } while tab.webView.isLoading && ContinuousClock.now < until
        XCTAssertFalse(tab.webView.isLoading, "WebKit fixture load timed out")
    }
    @MainActor private func payload(_ browser: BrowserWorkspace, _ name: String, _ args: JSONValue) async throws -> JSONValue {
        let result = try await browser.callTool(name, arguments: args)
        return try JSONDecoder().decode(JSONValue.self, from: Data(result["content"].array.first?["text"].string.utf8 ?? "".utf8))
    }
}
