import Foundation
import Combine

@MainActor
final class AgentsFeatureModel: ObservableObject {
    @Published private(set) var rows: [WorkspaceAgentRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var didLoad = false
    @Published private(set) var errorMessage: String?
    private let repository: WorkspaceRepositoryProtocol
    private var generation = 0
    private var targetThreadID: String?

    init(repository: WorkspaceRepositoryProtocol) { self.repository = repository }
    func refresh(threadID: String?) async {
        if targetThreadID != threadID {
            targetThreadID = threadID
            rows = []
            didLoad = false
        }
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let threads = try await repository.agents(threadID: threadID)
            guard generation == request, !Task.isCancelled else { return }
            rows = WorkspaceHierarchy.rows(from: threads)
            didLoad = true
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
