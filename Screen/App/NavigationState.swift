import Foundation

/// UI navigation, project lifecycle, and editor state.
@MainActor
final class NavigationState: ObservableObject {

    // MARK: - UI State

    @Published var showEditor: Bool = false
    @Published var errorMessage: String?

    // MARK: - Current Project

    @Published var currentProject: Any?
    @Published var currentProjectURL: URL?

    // MARK: - Editor State

    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    // MARK: - Methods

    func closeProject() {
        currentProject = nil
        currentProjectURL = nil
        showEditor = false
    }
}
