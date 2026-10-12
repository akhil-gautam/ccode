import XCTest
import AppKit
import WebKit
import CCodeCore
@testable import CCode

final class BrowserPickerTests: XCTestCase {
    @MainActor func testUserPickCapturesNonInteractiveElementWithoutActivatingThePage() async throws {
        let browser = BrowserWorkspace(), tab = try browser.open(URL(string: "http://127.0.0.1:38933/")!)
        addTeardownBlock { await browser.close() }
        try await load(tab, "<h1 id='heading'>Preview heading</h1><button onclick=\"document.body.dataset.clicked='yes'\">Submit</button>")
        // Picking is an explicit user action; it does not silently grant MCP access.
        try await browser.beginElementPicking(tab.id)
        XCTAssertTrue(tab.selectingElement)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('h1').dispatchEvent(new MouseEvent('mousemove',{bubbles:true})); document.querySelector('h1').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,button:0}))")
        try await settle { tab.selectedContext != nil }
        XCTAssertFalse(tab.selectingElement)
        XCTAssertTrue(tab.selectedContext?.contains("Preview heading") == true)
        XCTAssertTrue(tab.selectedContext?.contains("#heading") == true)
        XCTAssertFalse(browser.isAllowed(tab.currentURL))
        try await browser.beginElementPicking(tab.id)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('button').click()")
        try await settle { !tab.selectingElement }
        let clicked = try await tab.webView.evaluateJavaScript("document.body.dataset.clicked || 'no'") as? String
        XCTAssertEqual(clicked, "no", "Picking must intercept the page's original action")
        XCTAssertTrue(tab.selectedContext?.contains("Submit") == true)
    }

    @MainActor func testCancelEscapeAndNavigationCleanUpThePicker() async throws {
        let browser = BrowserWorkspace(), tab = try browser.open(URL(string: "http://127.0.0.1:38933/")!)
        addTeardownBlock { await browser.close() }
        try await load(tab, "<h1>Pick me</h1><button onclick=\"document.body.dataset.clicked='yes'\">Submit</button>")
        try await browser.beginElementPicking(tab.id)
        await browser.cancelElementPicking(tab.id)
        XCTAssertFalse(tab.selectingElement)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('button').click()")
        let clicked = try await tab.webView.evaluateJavaScript("document.body.dataset.clicked") as? String
        XCTAssertEqual(clicked, "yes")
        XCTAssertNil(tab.selectedContext)
        try await browser.beginElementPicking(tab.id)
        _ = try await tab.webView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
        try await settle { !tab.selectingElement }
        XCTAssertNil(tab.selectedContext)
        try await browser.beginElementPicking(tab.id)
        try await load(tab, "<h1>Next page</h1>")
        XCTAssertFalse(tab.selectingElement)
        XCTAssertNil(tab.selectedContext)
        browser.closeTab(tab.id)
        XCTAssertFalse(tab.selectingElement)
        XCTAssertNil(tab.webView.navigationDelegate)
    }

    @MainActor func testPickerRefusesAuthenticationAndCannotBeForgedFromThePageWorld() async throws {
        let browser = BrowserWorkspace(), tab = try browser.open(URL(string: "http://127.0.0.1:38933/")!)
        addTeardownBlock { await browser.close() }
        try await load(tab, "<h1>Public</h1>")
        try await browser.beginElementPicking(tab.id)
        let visibleHandler = try await tab.webView.evaluateJavaScript("!!window.webkit?.messageHandlers?.ccodePicker") as? Bool
        XCTAssertEqual(visibleHandler, false, "Page scripts must not forge native element context")
        _ = try await tab.webView.evaluateJavaScript("history.pushState({},'', '/login'); document.querySelector('h1').textContent='Private'; document.querySelector('h1').click()")
        try await settle { !tab.selectingElement }
        XCTAssertNil(tab.selectedContext)
        do { try await browser.beginElementPicking(tab.id); XCTFail("Authentication route picked") } catch {}
        try await load(tab, "<h1>Private</h1><input type='password' value='do-not-capture'>")
        do { try await browser.beginElementPicking(tab.id); XCTFail("Password page picked") } catch {}
        let login = try browser.open(URL(string: "http://127.0.0.1:38933/app")!, login: true)
        try await load(login, "<h1>Manual only</h1>")
        do { try await browser.beginElementPicking(login.id); XCTFail("Manual tab picked") } catch {}
        XCTAssertNil(login.selectedContext)
    }

    @MainActor func testRevocationAndTabSwitchRetainOnlyExplicitlyPickedContext() async throws {
        let browser = BrowserWorkspace(), tab = try browser.open(URL(string: "http://127.0.0.1:38933/")!)
        addTeardownBlock { await browser.close() }
        try await load(tab, "<h1 id='one'>One</h1>")
        browser.allowAgent(on: tab.id)
        try await browser.beginElementPicking(tab.id)
        browser.revokeAgent(on: tab.id)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('h1').click()")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(tab.selectedContext, "Revocation cancels an in-flight pick")
        XCTAssertFalse(tab.selectingElement)
        try await browser.beginElementPicking(tab.id)
        let second = try browser.open(URL(string: "http://127.0.0.1:38933/second")!)
        try await load(second, "<h1>Second</h1>")
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('h1').click()")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(tab.selectedContext, "A hidden tab must not supply a late pick")
        XCTAssertNil(second.selectedContext)
    }

    @MainActor private func load(_ tab: BrowserTab, _ html: String) async throws {
        tab.webView.loadHTMLString(html, baseURL: tab.url)
        let deadline = ContinuousClock.now + .seconds(5)
        repeat { try await Task.sleep(for: .milliseconds(20)) } while tab.webView.isLoading && ContinuousClock.now < deadline
        XCTAssertFalse(tab.webView.isLoading)
    }
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Native WebKit selection message did not settle")
    }
}
