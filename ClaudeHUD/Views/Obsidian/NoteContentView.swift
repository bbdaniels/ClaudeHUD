import SwiftUI
import AppKit

struct NoteContentView: View {
    let file: NoteFile
    let windowID: UUID
    let onClose: (UUID) -> Void

    @State private var content = ""
    @State private var lastSavedContent = ""
    @State private var saveError: String?
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Picker("", selection: $isEditing) {
                    Image(systemName: "pencil").tag(true)
                    Image(systemName: "eye").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 70)

                Text(file.name.replacingOccurrences(of: ".md", with: ""))
                    .font(.custom("Fira Sans", size: 13).weight(.medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Spacer()

                if content != lastSavedContent {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Saving...")
                            .font(.custom("Fira Sans", size: 11))
                            .foregroundColor(.secondary)
                    }
                } else if !content.isEmpty {
                    Text("Saved")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                }

                Button(action: { openInObsidian() }) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open in Obsidian")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.5)

            // Content area
            if isEditing {
                TextEditor(text: Binding(
                    get: { content },
                    set: { newValue in
                        content = newValue
                        scheduleAutoSave()
                    }
                ))
                .font(.custom("Fira Code", size: 14))
                .padding(8)
            } else {
                ScrollView {
                    ObsidianMarkdownView(content: content, filePath: file.path) { newContent in
                        content = newContent
                        lastSavedContent = newContent
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            if let error = saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
        .onAppear { loadContent() }
        .onDisappear { autoSaveTask?.cancel() }
    }

    private func loadContent() {
        let url = URL(fileURLWithPath: file.path)
        do {
            content = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n")
            lastSavedContent = content
        } catch {
            content = "Error loading: \(error.localizedDescription)"
        }
    }

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { saveContent() }
        }
    }

    private func saveContent() {
        let url = URL(fileURLWithPath: file.path)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            lastSavedContent = content
            saveError = nil
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func openInObsidian() {
        let encoded = file.relativePath.encodedForObsidianURL()
        if let vault = VaultSettings.loadFromDefaults().first,
           let vaultName = vault.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "obsidian://open?vault=\(vaultName)&file=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}
