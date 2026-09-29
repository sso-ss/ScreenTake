import SwiftUI

struct ExportView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if model.isExporting {
                    ProgressView(value: model.progress).frame(maxWidth: 260)
                    Text("Exporting \(Int(model.progress * 100))%").font(.title2.bold()).monospacedDigit()
                    Button("Cancel", role: .cancel) { model.cancelExport() }
                } else if model.exportedURL != nil {
                    Image(systemName: model.savedToPhotos ? "checkmark.circle.fill" : "film")
                        .font(.system(size: 48, weight: .light)).foregroundStyle(.tint)
                    Text(model.savedToPhotos ? "Saved to Photos" : "Video Ready").font(.title2.bold())
                    Text("\(Int(model.canvasSize.width)) x \(Int(model.canvasSize.height))  /  \(timeLabel(model.settings.trimmedDuration))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Button { Task { await model.saveToPhotos() } } label: {
                        Label(model.isSaving ? "Saving..." : "Save to Photos", systemImage: "square.and.arrow.down")
                            .frame(minWidth: 180, minHeight: 36)
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.isSaving || model.savedToPhotos)
                    Button { sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                } else {
                    Image(systemName: "xmark.circle").font(.system(size: 44, weight: .light))
                    Text("Export Stopped").font(.title2.bold())
                    Button("Try Again") { model.beginExport() }.buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding(24).frame(maxWidth: .infinity)
            .navigationTitle("Export").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(model.isExporting || model.isSaving)
                }
            }
            .interactiveDismissDisabled(model.isExporting || model.isSaving)
            .sheet(isPresented: $sharing) {
                if let url = model.exportedURL { ShareSheet(url: url) }
            }
            .alert("Couldn't Complete", isPresented: Binding(get: { model.errorMessage != nil },
                                                              set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}