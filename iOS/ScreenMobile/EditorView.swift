import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var showExport = false
    @State private var tool: EditorTool = .trim

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if model.sourceURL != nil {
                        if geometry.size.width > 650 && geometry.size.width > geometry.size.height {
                            HStack(spacing: 0) {
                                playback.padding(20)
                                Divider()
                                inspector.frame(width: 320)
                            }
                        } else {
                            VStack(spacing: 0) {
                                playback.padding(.horizontal, 20).padding(.top, 12)
                                    .frame(maxHeight: .infinity)
                                Divider().padding(.top, 12)
                                inspector.frame(height: min(310, geometry.size.height * 0.44))
                            }
                        }
                    } else {
                        VStack(spacing: 24) {
                            Image("WallpaperPrism")
                                .resizable().scaledToFill()
                                .frame(width: 140, height: 180).clipped()
                                .overlay { Image(systemName: "play.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(.white) }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                            Text("ScreenTake").font(.largeTitle.bold())
                            Button { showPhotos = true } label: {
                                Label("Import Video", systemImage: "photo.on.rectangle")
                                    .frame(minWidth: 160, minHeight: 36)
                            }.buttonStyle(.borderedProminent)
                            Button { showFiles = true } label: { Label("Choose from Files", systemImage: "folder") }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .disabled(model.busy)
                .overlay {
                    if model.isImporting {
                        ZStack {
                            Color(.systemBackground).opacity(0.85)
                            ProgressView("Opening video...").padding(24)
                        }
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(model.sourceURL == nil ? "" : "ScreenTake")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.sourceURL != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                            Button("Files", systemImage: "folder") { showFiles = true }
                        } label: { Label("Import Video", systemImage: "plus") }
                            .disabled(model.busy)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.beginExport()
                            showExport = true
                        } label: { Label("Export", systemImage: "square.and.arrow.up") }
                            .disabled(model.busy)
                    }
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $selectedPhoto, matching: .videos)
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await model.importPhoto(item); selectedPhoto = nil }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie]) { result in
                switch result {
                case .success(let url): Task { await model.importFile(url) }
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
            .onChange(of: model.settings) { _, _ in model.applyEdits() }
            .sheet(isPresented: $showExport) {
                ExportView(model: model)
            }
            .alert("Couldn't Complete", isPresented: Binding(get: { model.errorMessage != nil && !showExport },
                                                              set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }

    private var playback: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let size = model.canvasSize
                let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                PlayerSurface(player: model.player)
                    .frame(width: max(1, size.width * scale), height: max(1, size.height * scale))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(timeLabel(model.position)).monospacedDigit()
                    .frame(minWidth: 64, alignment: .leading)
                Spacer()
                Button { model.pause(); model.seek(model.position - 5) } label: {
                    Label("Back 5 seconds", systemImage: "gobackward.5")
                }
                Button { model.togglePlayback() } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                Button { model.pause(); model.seek(model.position + 5) } label: {
                    Label("Forward 5 seconds", systemImage: "goforward.5")
                }
                Spacer()
                Button { model.settings.muted.toggle() } label: {
                    Label(model.settings.muted ? "Unmute" : "Mute", systemImage: model.settings.muted ? "speaker.slash" : "speaker.wave.2")
                        .frame(width: 44, height: 44)
                }
            }
            .labelStyle(.iconOnly).font(.callout).foregroundStyle(.primary)
            timeline
        }
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: max(1, (geometry.size.width - 7) / 8), height: 36).clipped()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.6))
                        .frame(width: geometry.size.width * model.settings.trimStart / max(0.001, model.duration))
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.black.opacity(0.6))
                        .frame(width: geometry.size.width * (1 - model.settings.trimEnd / max(0.001, model.duration)))
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(.white).frame(width: 2)
                        .offset(x: min(geometry.size.width - 2, geometry.size.width * model.position / max(0.001, model.duration)))
                }
                .accessibilityHidden(true)
            }.frame(height: 36)
            Slider(value: Binding(get: { model.position }, set: { model.seek($0) }),
                   in: model.settings.trimStart...max(model.settings.trimStart + 0.001, model.settings.trimEnd),
                   onEditingChanged: { editing in if editing { model.pause() } })
                .accessibilityLabel("Playback position")
                .accessibilityValue(timeLabel(model.position))
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(EditorTool.allCases) { item in
                    Button { tool = item } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 18))
                            Text(item.rawValue).font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .foregroundStyle(tool == item ? Color.accentColor : .secondary)
                        .background(alignment: .bottom) {
                            if tool == item { Rectangle().fill(Color.accentColor).frame(height: 2) }
                        }
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(tool == item ? .isSelected : [])
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tool {
                    case .trim:
                        HStack {
                            Text("Trim").font(.headline)
                            Spacer()
                            Text(timeLabel(model.settings.trimmedDuration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button { model.settings.trimStart = 0; model.settings.trimEnd = model.duration } label: {
                                Label("Reset trim", systemImage: "arrow.counterclockwise")
                            }.labelStyle(.iconOnly).frame(width: 44, height: 32)
                        }
                        valueSlider("Start", value: $model.settings.trimStart,
                                    range: 0...max(0, model.settings.trimEnd - min(0.1, model.duration)),
                                    display: timeLabel(model.settings.trimStart))
                        valueSlider("End", value: $model.settings.trimEnd,
                                    range: min(model.duration, model.settings.trimStart + min(0.1, model.duration))...model.duration,
                                    display: timeLabel(model.settings.trimEnd))
                    case .canvas:
                        Picker("Aspect ratio", selection: $model.settings.format) {
                            ForEach(CanvasFormat.allCases) { format in Text(format.rawValue).tag(format) }
                        }.pickerStyle(.segmented)
                        valueSlider("Padding", value: $model.settings.padding, range: 0...0.2,
                                    display: "\(Int(model.settings.padding * 100))%")
                        valueSlider("Corners", value: $model.settings.cornerRadius, range: 0...0.12,
                                    display: "\(Int(model.settings.cornerRadius * 100))%")
                    case .background:
                        Text("Background").font(.headline)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                            ForEach(MobileBackground.allCases) { background in
                                Button { model.settings.background = background } label: {
                                    VStack(spacing: 6) {
                                        Group {
                                            if let name = background.assetName {
                                                Image(name).resizable().scaledToFill()
                                            } else {
                                                Rectangle().fill(background == .white ? Color.white : Color.black)
                                            }
                                        }
                                        .frame(height: 44).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(model.settings.background == background ? Color.accentColor : Color.gray.opacity(0.3),
                                                              lineWidth: model.settings.background == background ? 3 : 1)
                                        }
                                        Text(background.rawValue).font(.caption).foregroundStyle(.primary)
                                    }
                                }.buttonStyle(.plain)
                                    .accessibilityAddTraits(model.settings.background == background ? .isSelected : [])
                            }
                        }
                    case .zoom:
                        Toggle("Zoom", isOn: $model.settings.zoomEnabled)
                            .onChange(of: model.settings.zoomEnabled) { _, enabled in
                                if enabled && model.settings.zoomEnd <= model.settings.zoomStart { model.addZoomAtPlayhead() }
                            }
                        if model.settings.zoomEnabled {
                            Button { model.addZoomAtPlayhead() } label: { Label("Set at Playhead", systemImage: "plus.magnifyingglass") }
                            valueSlider("Start", value: $model.settings.zoomStart,
                                        range: model.settings.trimStart...max(model.settings.trimStart, model.settings.zoomEnd - 0.05),
                                        display: timeLabel(model.settings.zoomStart))
                            valueSlider("End", value: $model.settings.zoomEnd,
                                        range: min(model.settings.trimEnd, model.settings.zoomStart + 0.05)...model.settings.trimEnd,
                                        display: timeLabel(model.settings.zoomEnd))
                            valueSlider("Scale", value: $model.settings.zoomAmount, range: 1...3,
                                        display: String(format: "%.1fx", model.settings.zoomAmount))
                            valueSlider("Horizontal focus", value: $model.settings.focusX, range: 0...1,
                                        display: "\(Int(model.settings.focusX * 100))%")
                            valueSlider("Vertical focus", value: $model.settings.focusY, range: 0...1,
                                        display: "\(Int(model.settings.focusY * 100))%")
                        }
                    }
                }.padding(20)
            }
        }
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display).monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline)
            Slider(value: value, in: range).accessibilityLabel(title).accessibilityValue(display)
        }
    }
}

private enum EditorTool: String, CaseIterable, Identifiable {
    case trim = "Trim", canvas = "Frame", background = "Backdrop", zoom = "Zoom"
    var id: Self { self }
    var icon: String {
        switch self {
        case .trim: return "scissors"
        case .canvas: return "crop"
        case .background: return "photo"
        case .zoom: return "plus.magnifyingglass"
        }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) { view.playerLayer.player = player }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

func timeLabel(_ seconds: Double) -> String {
    let value = max(0, seconds.isFinite ? seconds : 0)
    return String(format: "%d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
}