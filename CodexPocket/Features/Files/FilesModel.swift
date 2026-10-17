import Foundation
import Combine

struct FileDirectoryState {
    var entries: [FileEntry] = []
    var isLoading = false
    var isLoaded = false
    var error: String?
}

struct FileTreeRow: Identifiable {
    let path: String
    let entry: FileEntry
    let depth: Int
    var id: String { path }
}

struct FileBreadcrumb: Identifiable {
    let path: String
    let name: String
    var id: String { path }
}

enum FileListFilter: String, CaseIterable {
    case all, files, folders
    var title: String {
        switch self {
        case .all: return "全部项目"
        case .files: return "文件"
        case .folders: return "文件夹"
        }
    }
}

@MainActor
final class FilesModel: ObservableObject {
    let root: String
    private let repository: FileRepositoryProtocol
    @Published private(set) var currentPath: String
    @Published private(set) var directories: [String: FileDirectoryState] = [:]
    @Published private(set) var expandedPaths: Set<String> = []
    @Published var query = ""
    @Published var showHidden = false
    @Published var filter: FileListFilter = .all
    @Published private(set) var document: FileDocument?
    @Published var draft = ""
    @Published var isEditing = false
    @Published private(set) var openingPath: String?
    @Published private(set) var isSaving = false
    @Published var fileError: String?
    @Published private(set) var conflict: FileDocument?
    @Published var showDiscardConfirmation = false

    init(repository: FileRepositoryProtocol, root: String) {
        self.repository = repository
        let path = ComputerPath.normalized(root.isEmpty ? "/" : root)
        self.root = path
        currentPath = self.root
    }

    var currentDirectory: FileDirectoryState { directories[currentPath] ?? FileDirectoryState() }
    var hasUnsavedChanges: Bool { document.map { draft != $0.text } ?? false }
    var isBusy: Bool { openingPath != nil || isSaving }
    var rows: [FileTreeRow] { treeRows(in: currentPath, depth: 0) }

    var breadcrumbs: [FileBreadcrumb] {
        let name = ComputerPath.lastComponent(root)
        var result = [FileBreadcrumb(path: root, name: name.isEmpty ? "/" : name)]
        guard ComputerPath.comparisonKey(currentPath) != ComputerPath.comparisonKey(root) else { return result }
        let relative = currentPath.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1)
        var path = root
        for part in relative.split(separator: "/") {
            path = FileBrowser.join(path, String(part))
            result.append(FileBreadcrumb(path: path, name: String(part)))
        }
        return result
    }

    func enterDirectory(_ path: String) {
        let path = ComputerPath.normalized(path)
        guard isWithinRoot(path), !isBusy else { return }
        currentPath = path
        query = ""
        loadDirectory(path)
    }

    private func treeRows(in path: String, depth: Int) -> [FileTreeRow] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtering = !search.isEmpty || filter != .all
        var result: [FileTreeRow] = []
        for entry in directories[path]?.entries ?? [] {
            if !showHidden && entry.name.hasPrefix(".") { continue }
            let childPath = FileBrowser.join(path, entry.name)
            let children = entry.isDir && (filtering || expandedPaths.contains(childPath))
                ? treeRows(in: childPath, depth: depth + 1) : []
            let matchesName = search.isEmpty || entry.name.localizedStandardContains(search)
            let matchesType = filter == .all || (filter == .folders ? entry.isDir : !entry.isDir)
            if matchesName && matchesType || !children.isEmpty {
                result.append(FileTreeRow(path: childPath, entry: entry, depth: depth))
                result.append(contentsOf: children)
            }
        }
        return result
    }

    private func isWithinRoot(_ path: String) -> Bool {
        ComputerPath.contains(path, in: root)
    }

    func openFile(_ path: String) {
        let path = ComputerPath.normalized(path)
        guard isWithinRoot(path), !isBusy, document == nil else { return }
        openingPath = path
        fileError = nil
        Task {
            defer { openingPath = nil }
            do {
                let loaded = try await repository.readText(path: path)
                draft = loaded.text
                isEditing = false
                conflict = nil
                document = loaded
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    func requestCloseDocument() {
        guard !isBusy else { return }
        if hasUnsavedChanges { showDiscardConfirmation = true }
        else { discardAndClose() }
    }

    func cancelDiscard() { showDiscardConfirmation = false }

    func discardAndClose() {
        guard !isBusy else { return }
        document = nil
        draft = ""
        conflict = nil
        isEditing = false
        fileError = nil
        showDiscardConfirmation = false
    }

    func saveDocument(closeAfterSaving: Bool = false) {
        guard let original = document, hasUnsavedChanges, !isBusy else { return }
        let text = draft
        isSaving = true
        fileError = nil
        showDiscardConfirmation = false
        Task {
            do {
                document = try await repository.saveText(original, text: text)
                conflict = nil
            } catch FileRepositoryError.conflict(let remote) {
                conflict = remote
            } catch {
                fileError = error.localizedDescription
            }
            isSaving = false
            if closeAfterSaving && !hasUnsavedChanges { discardAndClose() }
        }
    }

    func acceptRemoteVersion() {
        guard let current = document, !isBusy else { return }
        openingPath = current.path
        Task {
            defer { openingPath = nil }
            do {
                let latest = try await repository.readText(path: current.path)
                document = latest
                draft = latest.text
                conflict = nil
                fileError = nil
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    func load() { loadDirectory(currentPath) }

    private func loadDirectory(_ path: String, force: Bool = false) {
        var state = directories[path] ?? FileDirectoryState()
        guard !state.isLoading, force || !state.isLoaded else { return }
        state.isLoading = true
        state.error = nil
        directories[path] = state
        Task {
            do {
                let entries = try await repository.readDirectory(path: path)
                directories[path] = FileDirectoryState(entries: entries, isLoaded: true)
            } catch {
                var failed = directories[path] ?? FileDirectoryState()
                failed.isLoading = false
                failed.error = error.localizedDescription
                directories[path] = failed
            }
        }
    }

    func retryDirectory(_ path: String) {
        let path = ComputerPath.normalized(path)
        let visibleExpanded = rows.filter {
            $0.entry.isDir && expandedPaths.contains($0.path)
                && ComputerPath.contains($0.path, in: path)
                && ComputerPath.comparisonKey($0.path) != ComputerPath.comparisonKey(path)
        }.map(\.path)
        loadDirectory(path, force: true)
        for child in visibleExpanded { loadDirectory(child, force: true) }
    }

    func toggleDirectory(_ path: String) {
        let path = ComputerPath.normalized(path)
        guard isWithinRoot(path) else { return }
        if expandedPaths.contains(path) { expandedPaths.remove(path) }
        else {
            expandedPaths.insert(path)
            loadDirectory(path)
        }
    }
}
