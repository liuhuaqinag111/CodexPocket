import Foundation
import Combine

@MainActor
final class WorktreesFeatureModel: ObservableObject {
    @Published private(set) var groups: [WorkspaceWorktreeGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var didLoad = false
    @Published private(set) var chatsLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var chatErrorMessage: String?
    private let repository: WorkspaceRepositoryProtocol
    private var generation = 0
    private var targetDirectory: String?

    init(repository: WorkspaceRepositoryProtocol) { self.repository = repository }
    func refresh(cwd: String) async {
        if targetDirectory != cwd {
            targetDirectory = cwd
            groups = []
            didLoad = false
        }
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        chatErrorMessage = nil
        chatsLoaded = false
        defer { if generation == request { isLoading = false } }
        do {
            let trees = try await repository.worktrees(cwd: cwd)
            guard generation == request, !Task.isCancelled else { return }
            groups = WorkspaceWorktreeGroup.associate(trees: trees, threads: [])
            didLoad = true
            do {
                let threads = try await repository.threads()
                guard generation == request, !Task.isCancelled else { return }
                groups = WorkspaceWorktreeGroup.associate(trees: trees, threads: threads)
                chatsLoaded = true
            } catch {
                if generation == request, !Task.isCancelled { chatErrorMessage = error.localizedDescription }
            }
        } catch {
            if generation == request, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}
