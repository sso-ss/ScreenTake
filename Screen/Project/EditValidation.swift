import Foundation

extension VideoEditSettings {
    func validate(duration: Double) throws {
        _ = try trim.timeRange(duration: EditorAudio.time(duration))
        let timeline = try trim.timeline(duration: EditorAudio.time(duration))
        guard timeline.duration.seconds.isFinite, timeline.duration.seconds > 0,
              trim.end.map({ $0 <= duration + 0.001 }) ?? true,
              trim.cuts.allSatisfy({ $0.start >= 0 && $0.end <= duration + 0.001 }),
              trim.splits.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= duration }),
              trim.clipOrder.allSatisfy({ $0.start.seconds >= 0 && $0.end.seconds <= duration + 0.001 }) else {
            throw EditValidationError.invalid("Timeline ranges must lie inside the source video.")
        }
        let ordered = trim.clipOrder.sorted { $0.start < $1.start }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
            throw EditValidationError.invalid("Reordered clips cannot overlap in source time.")
        }
        if let clips = recordedAudioClips {
            guard Set(clips.map(\.id)).count == clips.count,
                  clips.allSatisfy({ [$0.start, $0.sourceStart, $0.duration].allSatisfy(\.isFinite)
                    && $0.start >= 0 && $0.sourceStart >= 0 && $0.duration > 0
                    && $0.sourceStart + $0.duration <= duration + 0.001 }) else {
                throw EditValidationError.invalid("Invalid recorded audio timing.")
            }
            let ordered = clips.sorted { $0.start < $1.start }
            guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.end <= $1.start + 0.000001 }) else {
                throw EditValidationError.invalid("Recorded audio clips cannot overlap.")
            }
            guard clips.allSatisfy({ $0.end <= timeline.duration.seconds + 0.001 }) else {
                throw EditValidationError.invalid("Recorded audio must lie inside the edited timeline.")
            }
            let video = trim.clips ?? []
            let videoLinks = video.compactMap(\.linkID), audioLinks = clips.compactMap(\.linkID)
            guard Set(videoLinks).count == videoLinks.count, Set(audioLinks).count == audioLinks.count else {
                throw EditValidationError.invalid("Each link must join exactly one video and audio section.")
            }
            guard Set(video.map(\.id)).count == video.count else {
                throw EditValidationError.invalid("Duplicate video clip identifiers.")
            }
            for clip in video where clip.linkID != nil {
                let partners = clips.filter { $0.linkID == clip.linkID }
                guard partners.count == 1, let partner = partners.first,
                      abs(partner.start - clip.start) < 0.001, abs(partner.sourceStart - clip.sourceStart) < 0.001,
                      abs(partner.duration - clip.duration) < 0.001 else {
                    throw EditValidationError.invalid("Linked video and audio must have matching timing.")
                }
            }
            guard clips.allSatisfy({ audio in audio.linkID == nil || video.contains(where: { $0.linkID == audio.linkID }) }) else {
                throw EditValidationError.invalid("Recorded audio has a missing video link.")
            }
        }
        func number(_ value: Double, _ range: ClosedRange<Double>, _ name: String) throws {
            guard value.isFinite, range.contains(value) else { throw EditValidationError.invalid("Invalid \(name).") }
        }
        try number(cursorScale, 0.5...3, "cursor size")
        try number(zoomLevel, 1...10, "zoom level")
        try number(desktopCornerRadius, 0...0.5, "corner radius")
        try number(originalAudioVolume, 0...1, "original audio volume")
        try number(voiceOverVolume, 0...1, "voiceover volume")
        if let faceBeautyAmount { try number(faceBeautyAmount, 0...1, "beauty intensity") }
        if let faceMakeup {
            for value in faceMakeup.values { try number(value, 0...1, "makeup intensity") }
        }
        let rect = crop.rect
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0,
              rect.maxX <= 1.000001, rect.maxY <= 1.000001 else {
            throw EditValidationError.invalid("Crop coordinates must lie inside the video.")
        }
        func camera(_ settings: CameraLayoutSettings) throws {
            try number(settings.zoom, 1...3, "camera zoom")
            try number(settings.centerX, 0...1, "camera horizontal position")
            try number(settings.centerY, 0...1, "camera vertical position")
            try number(settings.transitionDuration, 0.1...2, "camera transition duration")
        }
        try camera(cameraLayout)
        for change in cameraLayoutChanges {
            guard change.start.isFinite, change.start >= 0 else { throw EditValidationError.invalid("Invalid camera section.") }
            try camera(change.settings)
        }
        if let timing = videoOverlayTiming {
            guard [timing.start, timing.duration, timing.sourceStart].allSatisfy({ $0.isFinite }),
                  timing.start >= 0, timing.sourceStart >= 0, timing.duration > 0 else {
                throw EditValidationError.invalid("Invalid camera take timing.")
            }
        }
        let zooms = zoomSegments ?? []
        guard Set(zooms.map(\.id)).count == zooms.count else { throw EditValidationError.invalid("Duplicate zoom identifiers.") }
        for zoom in zooms {
            guard zoom.start.isFinite, zoom.end.isFinite, zoom.start >= 0,
                  zoom.end <= duration + 0.001, zoom.end > zoom.start else { throw EditValidationError.invalid("Invalid zoom range.") }
            try number(zoom.zoom, 1...10, "segment zoom")
            try number(zoom.centerX, 0...1, "zoom horizontal position")
            try number(zoom.centerY, 0...1, "zoom vertical position")
        }
        let sortedZooms = zooms.sorted { $0.start < $1.start }
        guard zip(sortedZooms, sortedZooms.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
            throw EditValidationError.invalid("Zoom segments cannot overlap.")
        }
        guard Set(voiceOvers.map(\.id)).count == voiceOvers.count else { throw EditValidationError.invalid("Duplicate voiceover identifiers.") }
        for clip in voiceOvers {
            guard [clip.start, clip.sourceStart, clip.duration, clip.sourceDuration].allSatisfy({ $0.isFinite }),
                  clip.start >= 0, clip.sourceStart >= 0, clip.duration > 0,
                  clip.sourceStart + clip.duration <= clip.sourceDuration + 0.001 else {
                throw EditValidationError.invalid("Invalid voiceover timing.")
            }
        }
    }
}

enum EditValidationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
