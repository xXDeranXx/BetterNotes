import SwiftUI

/// Title, template, paper size and cover color for a new notebook.
struct NewNotebookSheet: View {
    let create: (_ title: String, _ template: PageTemplate, _ size: PageSize, _ color: String) -> Void
    let cancel: () -> Void

    @State private var title = ""
    @State private var template = PageTemplate.lined
    @State private var format = PaperFormat.a4
    @State private var landscape = false
    @State private var color = LibraryModel.coverColors[0]

    private let templates: [PageTemplate] = [.blank, .lined, .grid, .dotted]

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") { TextField("Untitled", text: $title) }
                Section("Paper") {
                    Picker("Template", selection: $template) {
                        ForEach(templates, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Size", selection: $format) {
                        ForEach(PaperFormat.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Landscape", isOn: $landscape)
                }
                Section("Cover color") {
                    CoverColorPicker(selection: $color)
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        create(name.isEmpty ? "Untitled" : name, template,
                               landscape ? format.portrait.landscape : format.portrait, color)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct CoverColorPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 14) {
            ForEach(LibraryModel.coverColors, id: \.self) { hex in
                Button { selection = hex } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                        .overlay {
                            if selection == hex {
                                Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Where should this item go? A list of every folder, indented, plus the library itself.
/// Folders inside the moved item are not offered.
struct FolderPickerSheet: View {
    let item: URL
    let root: URL
    let folders: [FolderSummary]
    let choose: (URL) -> Void
    let cancel: () -> Void

    private func depth(_ url: URL) -> Int {
        max(0, url.standardizedFileURL.pathComponents.count - root.standardizedFileURL.pathComponents.count - 1)
    }

    private var choices: [FolderSummary] {
        let moved = item.standardizedFileURL.path
        return folders.filter { folder in
            let path = folder.url.standardizedFileURL.path
            return path != moved && !path.hasPrefix(moved + "/")
        }
        .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Button { choose(root) } label: { Label("Documents", systemImage: "tray.full") }
                ForEach(choices) { folder in
                    Button { choose(folder.url) } label: { Label(folder.name, systemImage: "folder") }
                        .padding(.leading, CGFloat(depth(folder.url)) * 22)
                }
            }
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }
    }
}

/// The trash: what was deleted, with Put Back and Delete Forever (both ask first, in a popover
/// next to the button that was pressed). Items older than 30 days are removed by the app on
/// launch. "Empty Trash" lives in the library's toolbar.
struct TrashView: View {
    let model: LibraryModel

    var body: some View {
        if model.trashed.isEmpty {
            ContentUnavailableView(
                "Trash is empty", systemImage: "trash",
                description: Text("Deleted notebooks and folders stay here for 30 days. Drag a notebook onto Trash in the sidebar to delete it."))
        } else {
            List(model.trashed) { item in
                TrashRow(item: item, model: model)
            }
        }
    }
}

/// One row. It owns the confirmation state, so each dialog is attached to its own button:
/// on the iPad a confirmation dialog is a popover that points at the view it is attached to.
private struct TrashRow: View {
    let item: TrashedItem
    let model: LibraryModel
    @State private var confirmPutBack = false
    @State private var confirmDelete = false

    private var name: String { item.url.deletingPathExtension().lastPathComponent }

    var body: some View {
        HStack {
            Image(systemName: item.url.pathExtension == NotebookPackage.fileExtension ? "book.closed" : "folder")
            VStack(alignment: .leading) {
                Text(name)
                Text("Deleted \(item.trashedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Put Back") { confirmPutBack = true }
                .buttonStyle(.bordered)
                .confirmationDialog("Put back \"\(name)\"?", isPresented: $confirmPutBack, titleVisibility: .visible) {
                    Button("Put Back") { Task { await model.putBack(item) } }
                } message: {
                    Text("It returns to its original folder.")
                }
            Button("Delete Forever", role: .destructive) { confirmDelete = true }
                .buttonStyle(.bordered)
                .confirmationDialog("Delete \"\(name)\" forever?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Forever", role: .destructive) { Task { await model.deleteForever(item) } }
                } message: {
                    Text("This cannot be undone.")
                }
        }
    }
}
