import XCTest
import CCodeCore

final class WorkspaceFileReferenceTests: XCTestCase, @unchecked Sendable {
    private func workspace() throws -> (Workspace, URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-file-links-\(UUID())")
        let primary = base.appendingPathComponent("primary"), extra = base.appendingPathComponent("extra"), foreign = base.appendingPathComponent("foreign")
        for folder in [primary, extra, foreign] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let workspace = try Workspace(root: primary.path, additionalDirectories: [extra.path])
        let canonicalPrimary = URL(fileURLWithPath: workspace.root), canonicalExtra = URL(fileURLWithPath: workspace.roots[1])
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        for folder in [canonicalPrimary, canonicalExtra, foreign] { try "first\nsecond\nthird\n".write(to: folder.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8) }
        return (workspace, canonicalPrimary, canonicalExtra, foreign)
    }

    // Catches conversation-relative links resolving against the displayed additional repository.
    func testRelativeAndAbsoluteLinksRetainCorrectRootAndLine() async throws {
        let (workspace, primary, extra, _) = try workspace()
        let relative = try await workspace.fileReference("same.txt:2")
        XCTAssertEqual(relative.root, primary.path); XCTAssertEqual(relative.path, primary.appendingPathComponent("same.txt").path)
        XCTAssertEqual(relative.line, 2)
        let absolute = try await workspace.fileReference(extra.appendingPathComponent("same.txt").absoluteString + "#L2-L3")
        XCTAssertEqual(absolute.root, extra.path); XCTAssertEqual(absolute.line, 2); XCTAssertEqual(absolute.endLine, 3)
        XCTAssertEqual(try absolute.selection(in: "first\nsecond\nthird\n"), NSRange(location: 6, length: 12))
        let column = try await workspace.fileReference("same.txt:2:3")
        XCTAssertEqual(try column.selection(in: "first\nsecond\n"), NSRange(location: 8, length: 0))
    }

    // Catches treating a valid Unix filename's colon/hash suffix as a guessed line number.
    func testLiteralExistingNameWinsOverLocationSuffix() async throws {
        let (workspace, primary, _, _) = try workspace()
        for name in ["notes:2", "notes#L2", "notes%20here.txt"] {
            try "literal".write(to: primary.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let reference = try await workspace.fileReference(name)
            XCTAssertEqual(reference.path, primary.appendingPathComponent(name).path); XCTAssertNil(reference.line)
        }
        try "spaced".write(to: primary.appendingPathComponent("a b.txt"), atomically: true, encoding: .utf8)
        let url = try await workspace.fileReference(primary.appendingPathComponent("a b.txt").absoluteString)
        XCTAssertEqual(url.path, primary.appendingPathComponent("a b.txt").path)
    }

    // Catches remote file hosts, arbitrary URLs, escapes, missing files or rebound symlinks granting local actions.
    func testForeignMissingAndRemoteReferencesRefuse() async throws {
        let (workspace, primary, _, foreign) = try workspace()
        try FileManager.default.createSymbolicLink(atPath: primary.appendingPathComponent("escape.txt").path, withDestinationPath: foreign.appendingPathComponent("same.txt").path)
        for raw in [foreign.appendingPathComponent("same.txt").path, "../foreign/same.txt", "escape.txt", "missing.txt", "file://other-host" + primary.appendingPathComponent("same.txt").path, "https://example.invalid/same.txt", "same.txt#L0", "same.txt#L3-L2", "same.txt:0", primary.appendingPathComponent("same.txt").absoluteString + "%00evil"] {
            do { _ = try await workspace.fileReference(raw); XCTFail("Accepted \(raw)") } catch {}
        }
    }

    // Catches nested roots using primary ownership and directories being misrepresented as editable files.
    func testMostSpecificDeclaredRootAndDirectoryCandidate() async throws {
        let (workspace, primary, _, _) = try workspace()
        let nested = primary.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "nested".write(to: nested.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let scoped = try Workspace(root: workspace.root, additionalDirectories: [nested.path])
        let file = try await scoped.fileReference("nested/file.txt")
        XCTAssertEqual(file.root, nested.path); XCTAssertEqual(file.candidate.relativePath, "file.txt")
        let folder = try await scoped.fileReference("nested")
        XCTAssertTrue(folder.isDirectory); XCTAssertEqual(folder.candidate.kind, .folder)
        do { _ = try folder.selection(in: "text"); XCTFail("Directory became text selection") } catch {}
    }

    // Catches UTF-16 offsets selecting the wrong line or splitting a surrogate pair, and invalid locations clamping silently.
    func testSelectionUsesCurrentDraftAndRejectsInvalidLocations() async throws {
        let (workspace, _, _, _) = try workspace()
        let line = try await workspace.fileReference("same.txt#L2")
        XCTAssertEqual(try line.selection(in: "😀\r\nsecond\r\n"), NSRange(location: 4, length: 6))
        do { _ = try line.selection(in: "only one line"); XCTFail("Missing line clamped") } catch {}
        let middle = try await workspace.fileReference("same.txt:1:2")
        do { _ = try middle.selection(in: "😀text"); XCTFail("Split surrogate") } catch {}
        let past = try await workspace.fileReference("same.txt:1:99")
        do { _ = try past.selection(in: "short"); XCTFail("Missing column clamped") } catch {}
    }
}
