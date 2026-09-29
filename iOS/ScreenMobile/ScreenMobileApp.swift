import SwiftUI

@main
struct ScreenMobileApp: App {
    @StateObject private var editor = EditorModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            EditorView(model: editor)
                .tint(Color(red: 0.42, green: 0.36, blue: 0.90))
                .task { await editor.restoreDraft() }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        editor.pause()
                        editor.saveDraft()
                    }
                }
        }
    }
}