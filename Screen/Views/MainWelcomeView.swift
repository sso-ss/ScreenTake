import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main Welcome View

struct MainWelcomeView: View {

    var onStartRecording: (() -> Void)?
    var onOpenVideo: ((URL) -> Void)?
    var onOpenSettings: (() -> Void)?

    @State private var isDragging = false
    @State private var isHoveringRecord = false
    @State private var isHoveringOpen = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(hex: "#0a0a12"),
                    Color(hex: "#111128"),
                    Color(hex: "#0a0a12")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Subtle grid pattern overlay
            Canvas { context, size in
                let spacing: CGFloat = 40
                for x in stride(from: 0, through: size.width, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.white.opacity(0.03)), lineWidth: 0.5)
                }
                for y in stride(from: 0, through: size.height, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.white.opacity(0.03)), lineWidth: 0.5)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App title
                VStack(spacing: 12) {
                    Text("ScreenTake")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(hex: "#a0a0b0")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Text("Capture · Edit · Export")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(hex: "#6b6b80"))
                        .tracking(2)
                }
                .padding(.bottom, 48)

                // Action buttons — horizontal row
                HStack(spacing: 20) {
                    // Record button
                    Button {
                        onStartRecording?()
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: "#ff3b30"))
                                .frame(width: 10, height: 10)

                            Text("New Recording")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(isHoveringRecord ? 0.12 : 0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        )
                        .scaleEffect(isHoveringRecord ? 1.03 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { isHoveringRecord = h } }

                    // Open video button
                    Button {
                        openVideoPanel()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 13))

                            Text("Open File")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(Color(hex: "#a0a0b0"))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(isHoveringOpen ? 0.08 : 0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                )
                        )
                        .scaleEffect(isHoveringOpen ? 1.03 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { isHoveringOpen = h } }
                }

                Spacer()

                // Drop hint at bottom
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 11))
                    Text("Drop a video file to import")
                        .font(.system(size: 12))
                }
                .foregroundColor(Color(hex: "#4a4a5a"))
                .padding(.bottom, 24)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDragging ? Color(hex: "#5856d6").opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.movie, .fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "#6b6b80"))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .padding(12)
        }
    }

    // MARK: - Actions

    private func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            onOpenVideo?(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        onOpenVideo?(url)
                    }
                }
            }
            return true
        }
        return false
    }
}
