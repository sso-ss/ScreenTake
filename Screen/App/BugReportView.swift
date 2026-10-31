import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    func reportableError(_ title: String, error: Binding<String?>) -> some View {
        modifier(ReportableErrorModifier(title: title, error: error))
    }
}

private struct ReportableErrorModifier: ViewModifier {
    let title: String
    @Binding var error: String?

    func body(content: Content) -> some View {
        // Capture the message before alert dismissal clears the source binding.
        let message = error ?? "Unknown error"
        return content.alert(LocalizedStringKey(title), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
            Button("Report a Bug…") {
                error = nil
                Task { @MainActor in
                    await Task.yield()
                    BugReporter.open(error: AppLanguage.text(title) + ": " + AppLanguage.text(message))
                }
            }
        } message: {
            Text(LocalizedStringKey(message))
        }
    }
}

@MainActor
final class BugReportWindowController: NSWindowController, NSWindowDelegate {
    init(error: String?, sourceWindow: NSWindow?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppLanguage.text("Report a Bug…")
        window.identifier = NSUserInterfaceItemIdentifier("bugReport")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: BugReportView(error: error, sourceWindow: sourceWindow,
                                                                 close: { [weak window] in window?.close() })
            .environment(\.locale, AppLanguage.current.locale)
            .accentColor(DesignColors.accent))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        // Release local screenshots and report text when the user closes the report.
        window?.contentView = nil
    }
}

struct BugReportView: View {
    let error: String?
    weak var sourceWindow: NSWindow?
    var close: () -> Void
    @State private var details = ""
    @State private var logs = ""
    @State private var loadingLogs = true
    @State private var includeLogs = true
    @State private var showLogs = false
    @State private var screenshot: CGImage?
    @State private var editingScreenshot = false
    @State private var loadingImage = false
    @State private var attachmentError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Report a Bug…").font(Typography.display)
                Text("Recent logs and app information are prepared automatically.")
                    .font(Typography.body).foregroundStyle(DesignColors.secondaryLabel)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error {
                        Label("Error", systemImage: "exclamationmark.triangle").font(Typography.heading)
                        Text(BugReportDiagnostics.redact(error)).font(Typography.body).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesignColors.inputBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What were you doing? (optional)").font(Typography.heading)
                        TextEditor(text: $details).font(Typography.body).frame(height: 80)
                            .padding(4).background(DesignColors.controlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DesignColors.inputBorder))
                            .accessibilityLabel("What were you doing? (optional)")
                            .accessibilityIdentifier("bugReportDetails")
                    }
                    screenshotSection
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Include recent error logs", isOn: $includeLogs)
                                .accessibilityIdentifier("bugReportIncludeLogs")
                            if loadingLogs { ProgressView().controlSize(.small) }
                        }
                        Text("ScreenTake version and macOS version are included. Common file paths, email addresses and credentials are removed from logs. Review before sharing.")
                            .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                        DisclosureGroup("View and edit diagnostics", isExpanded: $showLogs) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(appInformation).font(Typography.monoSmall).textSelection(.enabled)
                                if loadingLogs {
                                    ProgressView().controlSize(.small)
                                } else if includeLogs {
                                    TextEditor(text: $logs).font(Typography.monoSmall).frame(height: 120)
                                        .accessibilityLabel("Recent ScreenTake logs")
                                }
                            }.padding(.top, 8)
                        }
                    }
                    if let attachmentError {
                        Text(LocalizedStringKey(attachmentError)).font(Typography.caption).foregroundStyle(DesignColors.error)
                    }
                    Text("Reports are public on GitHub and require a GitHub account. Videos and project files are not included.")
                        .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
                }.padding(24)
            }
            Divider()
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    .buttonStyle(CompactActionButtonStyle(size: .medium))
                Spacer()
                Button("Continue on GitHub", action: continueOnGitHub)
                    .buttonStyle(CompactActionButtonStyle(prominent: true, size: .medium))
                    .disabled(loadingLogs || loadingImage)
                    .accessibilityIdentifier("bugReportContinue")
            }.padding(20)
        }
        .frame(width: 620, height: 720)
        .background(DesignColors.windowBackground)
        .sheet(isPresented: $editingScreenshot) {
            if let screenshot {
                BugReportRedactionView(image: screenshot) { edited in
                    self.screenshot = edited
                    editingScreenshot = false
                } cancel: { editingScreenshot = false }
            }
        }
        .task {
            let collected = await Task.detached(priority: .utility) { BugReportDiagnostics.collect() }.value
            guard !Task.isCancelled else { return }
            logs = collected
            loadingLogs = false
        }
    }

    private var appInformation: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "ScreenTake \(version) (\(build))\n\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Screenshot (optional)").font(Typography.heading)
            HStack {
                Button(action: captureWindow) { Label("Capture App Window", systemImage: "camera") }
                    .disabled(sourceWindow?.isVisible != true || loadingImage)
                    .accessibilityIdentifier("bugReportCapture")
                Button(action: chooseImage) { Label("Attach Image…", systemImage: "photo") }
                    .disabled(loadingImage).accessibilityIdentifier("bugReportAttach")
                if loadingImage { ProgressView().controlSize(.small) }
            }.buttonStyle(CompactActionButtonStyle(size: .medium))
            if let screenshot {
                Image(decorative: screenshot, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 150)
                    .background(DesignColors.previewBackground, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Attached screenshot preview")
                HStack {
                    Button("Hide Sensitive Areas") { editingScreenshot = true }
                        .accessibilityIdentifier("bugReportRedact")
                    Button("Remove") { self.screenshot = nil }
                        .accessibilityIdentifier("bugReportRemove")
                }.buttonStyle(CompactActionButtonStyle(size: .medium))
                Text("The reviewed screenshot will be copied. Paste it into the GitHub issue with Command-V before submitting.")
                    .font(Typography.caption).foregroundStyle(DesignColors.secondaryLabel)
            }
        }
    }

    private func captureWindow() {
        attachmentError = nil
        guard let sourceWindow, sourceWindow.isVisible,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                 CGWindowID(sourceWindow.windowNumber), [.boundsIgnoreFraming]),
              let flattened = BugReportScreenshot.flatten(image) else {
            attachmentError = "Could not capture the app window. Check Screen Recording permission or attach an image instead."
            return
        }
        screenshot = flattened
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            loadingImage = true
            attachmentError = nil
            Task { @MainActor in
                defer { loadingImage = false }
                do {
                    screenshot = try await Task.detached(priority: .userInitiated) { try BugReportScreenshot.load(url) }.value
                } catch {
                    attachmentError = "Choose a valid image file, such as PNG, JPEG, or HEIC."
                }
            }
        }
    }

    private func continueOnGitHub() {
        guard let url = BugReporter.issueURL(error: error, details: details,
                                             diagnostics: includeLogs ? logs : "", includesScreenshot: screenshot != nil) else { return }
        if let screenshot {
            guard let data = BugReportScreenshot.png(screenshot) else {
                attachmentError = "Could not prepare the screenshot. Try attaching it again."
                return
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setData(data, forType: .png) else {
                attachmentError = "Could not copy the screenshot. Try again."
                return
            }
        }
        guard NSWorkspace.shared.open(url) else {
            attachmentError = "Could not open GitHub. Check your default browser and try again."
            return
        }
        // This opens a draft. GitHub confirms submission after the user reviews it.
        close()
    }
}

struct BugReportRedactionView: View {
    let image: CGImage
    var save: (CGImage) -> Void
    var cancel: () -> Void
    @State private var masks: [CGRect] = []
    @State private var drag: CGRect?
    @State private var saveError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hide Sensitive Areas").font(Typography.display)
            Text("Drag over anything you want to hide. Selected areas are covered with solid black.")
                .font(Typography.body).foregroundStyle(DesignColors.secondaryLabel)
            GeometryReader { geometry in
                let available = geometry.size
                let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    ForEach(Array(masks.enumerated()), id: \.offset) { _, rect in cover(rect, size: size) }
                    if let drag { cover(drag, size: size) }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag = BugReportScreenshot.mask(from: $0.startLocation, to: $0.location, in: size) }
                    .onEnded {
                        if let mask = BugReportScreenshot.mask(from: $0.startLocation, to: $0.location, in: size) { masks.append(mask) }
                        drag = nil
                    })
                .accessibilityLabel("Drag to cover sensitive areas")
                .accessibilityIdentifier("bugReportRedactionCanvas")
                .frame(width: available.width, height: available.height)
            }.frame(height: 390).background(DesignColors.previewBackground)
            if saveError { Text("Could not save screenshot changes. Try again.").foregroundStyle(DesignColors.error) }
            HStack {
                Button("Undo") { if !masks.isEmpty { masks.removeLast() } }.disabled(masks.isEmpty)
                Button("Clear All") { masks.removeAll() }.disabled(masks.isEmpty)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let flattened = BugReportScreenshot.flatten(image, masks: masks) else { saveError = true; return }
                    save(flattened)
                }.buttonStyle(CompactActionButtonStyle(prominent: true, size: .medium))
                    .accessibilityIdentifier("bugReportSaveRedaction")
            }.buttonStyle(CompactActionButtonStyle(size: .medium))
        }.padding(24).frame(width: 760).background(DesignColors.windowBackground)
    }

    private func cover(_ rect: CGRect, size: CGSize) -> some View {
        Rectangle().fill(.black)
            .frame(width: rect.width * size.width, height: rect.height * size.height)
            .offset(x: rect.minX * size.width, y: rect.minY * size.height)
            .allowsHitTesting(false)
    }
}
