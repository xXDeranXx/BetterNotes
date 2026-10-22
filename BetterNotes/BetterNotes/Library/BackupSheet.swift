import SwiftUI

/// "Back Up": shows how big the backup will be and how much room the iPad has, before
/// anything is made, because a backup needs about that much free space until it is saved
/// somewhere else (SPEC: the free Apple account has no iCloud, storage can be tight).
struct BackupSheet: View {
    /// The folder to back up: the whole library, or one folder inside it.
    let source: URL
    let title: String
    let isWholeLibrary: Bool
    let lastBackup: Date?
    /// Called when the file was really shared or saved.
    let didBackUp: () -> Void
    let close: () -> Void

    @State private var size: Int64?
    @State private var free: Int64?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var sharedFile: SharedFile?
    @State private var madeFile: URL?

    /// Making the file needs about its size again (the ZIP itself), plus some room.
    private var needed: Int64 { (size ?? 0) + (size ?? 0) / 10 }
    private var hasRoom: Bool { free.map { needed < $0 } ?? true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Size of the backup", size.map(StorageSize.format) ?? "Measuring…")
                    row("Free space on this iPad", free.map(StorageSize.format) ?? "Unknown")
                    if isWholeLibrary {
                        row("Last backup", lastBackup.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Never")
                    }
                } footer: {
                    Text("Notebooks are PDFs and ink, which hardly shrink in a ZIP, so the file is about as big as the number above. Thumbnails and the trash are left out. The file is made temporarily on this iPad; after you save it (Files, a USB drive, another cloud) it is removed again.")
                }
                if !hasRoom {
                    Section {
                        Label("Not enough free space. Free some room, or back up a single folder instead: touch and hold a folder in the library and choose Back Up.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button {
                        make()
                    } label: {
                        HStack {
                            Text(isWorking ? "Making the backup…" : "Create Backup…")
                            if isWorking { ProgressView().padding(.leading, 4) }
                        }
                    }
                    .disabled(isWorking || size == nil || size == 0 || !hasRoom)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close", action: close).disabled(isWorking) } }
            .task {
                free = StorageSize.freeSpace(at: source)
                size = await StorageSize.measure(source)
            }
            .sheet(item: $sharedFile, onDismiss: discardShared) { file in
                ShareSheet(url: file.url) { completed in
                    if completed { didBackUp() }
                    sharedFile = nil
                }
            }
            .alert("Backup failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }

    private func make() {
        isWorking = true
        let source = source, name = isWholeLibrary ? nil : title
        Task {
            defer { isWorking = false }
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackup.makeBackup(of: source, name: name)
                }.value
                madeFile = file
                sharedFile = SharedFile(url: file)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The share sheet is closed (shared, saved or cancelled): the temporary file is not needed.
    private func discardShared() {
        if let madeFile { LibraryBackup.discard(madeFile) }
        madeFile = nil
    }
}
