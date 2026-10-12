import XCTest
import Foundation
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class ElicitationTests: XCTestCase, @unchecked Sendable {
    @MainActor func testQuestionCardFitsCompactAndWideWindows() throws {
        let request = try ElicitationRequest(params: ["mode": "form", "sessionId": "s", "message": "Choose how this implementation should work before I change your project.", "requestedSchema": ["type": "object", "properties": ["question": ["type": "string", "title": "Storage", "oneOf": [["const": "sqlite", "title": "SQLite", "description": "An indexed local database"], ["const": "files", "title": "Files", "description": "Preserve current storage"]]], "notes": ["type": "string", "title": "Notes"]]]])
        for width: CGFloat in [340, 720] {
            for appearance in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: InteractionForm(request: request, agentName: "Claude", resolve: { _, _ in }).frame(width: width).preferredColorScheme(appearance))
                let size = host.fittingSize
                XCTAssertEqual(size.width, width, accuracy: 1)
                XCTAssertGreaterThan(size.height, 100)
                XCTAssertLessThan(size.height, 530, "Question card must not stretch the composer out of the window")
            }
        }
    }
    func testQuestionOptionsUseWireValuesAndPreserveCustomNotes() throws {
        let request = try ElicitationRequest(params: ["mode": "form", "sessionId": "s", "toolCallId": "ask", "message": "Choose the implementation", "requestedSchema": ["type": "object", "properties": [
            "question_0": ["type": "string", "title": "Storage", "oneOf": [["const": "sqlite", "title": "SQLite", "description": "Local storage"], ["const": "files", "title": "Files"]]],
            "question_0_custom": ["type": "string", "title": "Other"],
            "question_1": ["type": "array", "items": ["anyOf": [["const": "unit", "title": "Unit"], ["const": "integration", "title": "Integration"]]]]
        ]]])
        XCTAssertEqual(request.fields.map(\.id), ["question_0", "question_0_custom", "question_1"])
        XCTAssertEqual(request.fields[0].choices.map(\.value), ["sqlite", "files"])
        let content: JSONValue = ["question_0": "sqlite", "question_0_custom": "Keep the existing file importer", "question_1": ["unit", "integration"]]
        XCTAssertEqual(try request.response(action: .accept, content: content), ["action": "accept", "content": content])
        XCTAssertThrowsError(try request.response(action: .accept, content: ["question_0": "SQLite"]))
        XCTAssertThrowsError(try request.response(action: .accept, content: ["question_1": ["unit", "unknown"]]))
        XCTAssertThrowsError(try request.response(action: .accept, content: ["question_1": ["unit", "unit"]]))
        XCTAssertEqual(try request.response(action: .decline, content: content), ["action": "decline"])
        XCTAssertEqual(try request.response(action: .cancel), ["action": "cancel"])
    }

    func testPrimitiveSchemaValidationAndDefaults() throws {
        let request = try ElicitationRequest(params: ["mode": "form", "requestId": 9, "message": "Settings", "requestedSchema": ["type": "object", "required": ["name", "count"], "properties": [
            "name": ["type": "string", "minLength": 2, "maxLength": 8],
            "count": ["type": "integer", "minimum": 1, "maximum": 10, "default": 3],
            "enabled": ["type": "boolean", "default": false],
            "ratio": ["type": "number", "minimum": 0, "maximum": 1]
        ]]])
        XCTAssertEqual(request.defaultContent, ["count": 3, "enabled": false])
        XCTAssertThrowsError(try request.response(action: .accept, content: request.defaultContent), "Defaults alone must not submit a required missing answer")
        XCTAssertNoThrow(try request.response(action: .accept, content: ["name": "project", "count": 3, "enabled": false, "ratio": .number(0.5)]))
        for invalid: JSONValue in [["name": "x", "count": 3], ["name": "project", "count": .number(1.5)], ["name": "project", "count": 11], ["name": "project", "count": 3, "enabled": "true"], ["name": "project", "count": 3, "extra": "unknown"]] {
            XCTAssertThrowsError(try request.response(action: .accept, content: invalid))
        }
    }

    func testTextPatternAndSelectionBoundsAreEnforced() throws {
        let request = try ElicitationRequest(params: ["mode": "form", "sessionId": "s", "message": "Validate", "requestedSchema": ["type": "object", "properties": [
            "ticket": ["type": "string", "pattern": "^ENG-[0-9]+$"],
            "tests": ["type": "array", "minItems": 1, "maxItems": 2, "items": ["type": "string", "enum": ["unit", "integration", "ui"]]]
        ]]])
        XCTAssertThrowsError(try request.response(action: .accept, content: ["ticket": "wrong"]))
        XCTAssertThrowsError(try request.response(action: .accept, content: ["tests": []]))
        XCTAssertThrowsError(try request.response(action: .accept, content: ["tests": ["unit", "integration", "ui"]]))
        XCTAssertNoThrow(try request.response(action: .accept, content: ["ticket": "ENG-42", "tests": ["unit"]]))
    }

    func testMalformedScopeOrUnsupportedSchemaRejectsBeforeShowingCard() throws {
        let valid: JSONValue = ["mode": "form", "sessionId": "s", "message": "Choose", "requestedSchema": ["type": "object", "properties": ["pick": ["type": "string", "enum": ["a", "b"]]]]]
        for patch: JSONValue in [["mode": "unknown"], ["sessionId": ""], ["sessionId": .null], ["requestId": 8], ["requestedSchema": ["type": "object", "properties": ["nested": ["type": "object"]]]], ["requestedSchema": ["type": "object", "required": ["absent"], "properties": [:]]], ["requestedSchema": ["type": "object", "properties": ["secret": ["type": "string", "format": "password"]]]]] {
            XCTAssertThrowsError(try ElicitationRequest(params: valid.merging(patch)))
        }
        XCTAssertEqual(try ElicitationRequest(params: valid).fields[0].choices.map(\.title), ["a", "b"])
    }

    func testURLInteractionRequiresSafeExplicitTargetAndOpaqueIdentity() throws {
        let valid: JSONValue = ["mode": "url", "requestId": 1, "elicitationId": "opaque-oauth", "url": "https://example.com/authorize", "message": "Connect service"]
        let request = try ElicitationRequest(params: valid)
        XCTAssertEqual(request.url?.host, "example.com")
        XCTAssertEqual(try request.response(action: .accept), ["action": "accept"])
        XCTAssertNoThrow(try ElicitationRequest(params: valid.merging(["url": "http://localhost:3456/authorize"])))
        for patch: JSONValue in [["url": "javascript:alert(1)"], ["url": "file:///etc/passwd"], ["url": "http://remote.example/authorize"], ["url": "https://user:password@example.com/auth"], ["elicitationId": ""]] {
            XCTAssertThrowsError(try ElicitationRequest(params: valid.merging(patch)))
        }
    }
}
