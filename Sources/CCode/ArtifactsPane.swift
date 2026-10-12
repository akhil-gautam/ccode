import SwiftUI
import AppKit
import Quartz
import CCodeCore

struct ArtifactsPane: View {
    let chat: ChatSession
    @State private var query = ""
    @State private var selectedPath: String?
    @State private var snapshot: WorkspaceArtifactSnapshot?
    private var url: URL? { snapshot?.url }
    @State private var markdown: String?
    @State private var failure: String?
    @State private var revision = 0
    private var files: [String] {
        let extensions: Set<String> = ["md", "markdown", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "html", "htm", "txt", "csv", "docx", "xlsx", "pptx", "rtf", "mp4", "mov", "mp3", "wav"]
        return chat.files.filter { extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass"); TextField("Find an artifact", text: $query).textFieldStyle(.plain) }.padding(12).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack { ForEach(files, id: \.self) { path in
                    Button { selectedPath = path } label: { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc.richtext").font(.caption).padding(8).background(selectedPath == path ? Palette.selected : Palette.muted, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain).help(path)
                } }.padding(.horizontal, 12)
            }.frame(height: 46)
            Divider()
            if let path = selectedPath {
                HStack {
                    Text(path).font(.caption.monospaced()).lineLimit(1).help(path)
                    Spacer()
                    Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Reload artifact")
                    if let url { Button { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path) } label: { Image(systemName: "folder") }.help("Reveal artifact in Finder") }
                }.buttonStyle(.plain).padding(12)
                if let failure { Text(failure).foregroundStyle(.secondary).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let markdown { ScrollView { MarkdownText(text: markdown, streaming: false).padding(20) } }
                else if let url { ArtifactPreview(url: url, revision: revision) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else { Text(files.isEmpty ? "Documents, images and media in this project appear here." : "Select an artifact to preview").foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: "\(selectedPath ?? "")-\(revision)") {
            snapshot = nil; markdown = nil; failure = nil
            guard let path = selectedPath else { return }
            do {
                let scoped = try await chat.workspace.scoped(chat.workspace.filePath(path))
                let text = ["md", "markdown"].contains(scoped.pathExtension.lowercased()) ? try await chat.workspace.read(scoped.path) : nil
                guard !Task.isCancelled else { return }
                snapshot = text == nil || chat.workspace.environment.isLocal ? try await chat.workspace.artifactSnapshot(scoped.path) : nil
                markdown = text
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onDisappear { snapshot = nil }
        .onChange(of: chat.files) { _, files in if let selectedPath, !files.contains(selectedPath) { self.selectedPath = nil } }
    }
}

struct ArtifactPreview: NSViewRepresentable {
    let url: URL
    let revision: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if context.coordinator.url != url { view.previewItem = url as NSURL; context.coordinator.url = url }
        if context.coordinator.revision != revision { view.refreshPreviewItem(); context.coordinator.revision = revision }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) { view.close() }
    final class Coordinator { var url: URL?; var revision = -1 }
}
