import Foundation

/// Public MCP schemas. Keep these in sync with EditorEdits and the native dispatcher.
enum MCPToolCatalog {
    typealias Schema = [String: Any]

    static func object(_ properties: Schema, required: [String] = [], extra: Schema = [:]) -> Schema {
        var result: Schema = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        result.merge(extra) { _, new in new }
        return result
    }

    static func number(_ minimum: Double? = nil, _ maximum: Double? = nil, extra: Schema = [:]) -> Schema {
        var result: Schema = ["type": "number"]
        if let minimum { result["minimum"] = minimum }
        if let maximum { result["maximum"] = maximum }
        result.merge(extra) { _, new in new }
        return result
    }

    static func choices(_ values: String...) -> Schema { ["type": "string", "enum": values] }
    static func array(_ item: Schema, extra: Schema = [:]) -> Schema {
        var result: Schema = ["type": "array", "items": item]
        result.merge(extra) { _, new in new }
        return result
    }

    static let uuid: Schema = ["type": "string", "format": "uuid"]
    static let boolean: Schema = ["type": "boolean"]
    static let time = number(0)
    static let fileURL: Schema = ["type": "string", "pattern": "^file:///", "description": "Absolute local file URL, e.g. file:///Users/me/take.mov."]
    static let cut = object(["id": uuid, "start": time, "end": time], required: ["id", "start", "end"])
    static let mediaClip = object([
        "id": uuid, "start": time, "sourceStart": time,
        "duration": number(0, extra: ["exclusiveMinimum": 0]), "linkID": ["type": ["string", "null"], "format": "uuid"]
    ], required: ["id", "start", "sourceStart", "duration"])
    static let exactRange = object([
        "startValue": ["type": "integer", "minimum": 0], "startScale": ["type": "integer", "minimum": 1],
        "durationValue": ["type": "integer", "minimum": 1], "durationScale": ["type": "integer", "minimum": 1]
    ], required: ["startValue", "startScale", "durationValue", "durationScale"])
    static let camera = object([
        "layout": choices("overlay", "fullScreen"), "zoom": number(1, 3), "centerX": number(0, 1), "centerY": number(0, 1),
        "followFace": boolean, "smoothTransition": boolean, "transitionDuration": number(0.1, 2),
        "transitionMotion": choices("smooth", "linear", "easeIn", "easeOut")
    ], extra: ["description": "Replaces camera framing; omitted members use native defaults."])

    static let textColor: Schema = ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"]
    static let textOverlay = object([
        "id": uuid, "text": ["type": "string", "maxLength": 10000], "start": number(0, 86400), "duration": number(0.05, 86400),
        "fontName": ["type": "string", "maxLength": 200], "fontSize": number(8, 240),
        "bold": boolean, "italic": boolean, "underline": boolean,
        "letterCase": choices("Original", "UPPERCASE", "lowercase", "Title Case"), "color": textColor,
        "characterSpacing": number(-10, 50), "lineSpacing": number(0, 100),
        "alignment": choices("Left", "Center", "Right"), "boxWidth": number(0.1, 1),
        "scale": number(0.1, 3), "uniformScale": boolean, "scaleY": number(0.1, 3),
        "x": number(0, 1), "y": number(0, 1), "rotation": number(-180, 180), "opacity": number(0, 1),
        "strokeEnabled": boolean, "strokeColor": textColor, "strokeWidth": number(0, 20),
        "backgroundEnabled": boolean, "backgroundStyle": choices("Block", "Per Line"), "backgroundColor": textColor,
        "backgroundOpacity": number(0, 1), "backgroundRadius": number(0, 100),
        "paddingX": number(0, 200), "paddingY": number(0, 200),
        "backgroundOffsetX": number(-200, 200), "backgroundOffsetY": number(-200, 200)
    ], required: ["id", "text", "start", "duration"], extra: ["description": "Text in edited-video seconds. x/y are the text center on the output canvas, normalized from top-left; size/spacing use a 1080-point canvas height. Omitted appearance fields use native defaults (System 64, centered white text). Preserve complete existing objects when editing; omitted fields reset to defaults."])

    static let edits = object([
        "trim": object(["start": time, "end": ["type": ["number", "null"], "minimum": 0], "cuts": array(cut),
                        "splits": array(time), "clipOrder": array(exactRange), "clips": array(mediaClip),
                        "timelineLength": time],
                       extra: ["description": "Replaces the timeline. Legacy cuts and clipOrder use source time. clips use output start, sourceStart, duration, and optional linkID; timelineLength preserves output gaps. Preserve complete existing trim values when editing one part."]),
        "removeRanges": array(cut, extra: ["description": "Append cuts in source seconds. Supply a UUID for each cut."]),
        "removeOutputRanges": array(cut, extra: ["minItems": 1, "description": "Remove edited-video seconds from screen, recorded audio, and added audio together; ripple remaining content. Supply a UUID for each nonoverlapping range. Use with output-time find_silences suggestions."]),
        "ratio": choices("original", "landscape", "desktop", "square", "portrait", "vertical"),
        "layout": choices("desktop", "iPhone", "duo", "iPhoneDuoClosed", "iPhoneDuoUnfolded"),
        "wallpaper": choices("sonoma", "aurora", "sunset", "ocean", "blossom", "nebula", "moss", "dusk", "prism", "lagoon", "ember", "midnight", "silk", "pastel", "breeze", "mint"),
        "customBackgroundImagePath": ["type": "string", "pattern": "^/", "description": "Absolute path to a PNG, JPEG, HEIC, or other supported image. The native editor imports and embeds a bounded PNG. Takes precedence over wallpaper and clearCustomBackgroundImage in the same batch."],
        "clearCustomBackgroundImage": boolean,
        "backgroundEnabled": boolean, "desktopCornerRadius": number(0, 0.5),
        "phoneCornerRadius": number(0, 0.2),
        "crop": object(["rect": array(array(number(0, 1), extra: ["minItems": 2, "maxItems": 2]),
                                       extra: ["minItems": 2, "maxItems": 2, "description": "CGRect encoded as [[x,y],[width,height]], normalized to source dimensions."])], required: ["rect"]),
        "phoneMode": choices("fit", "fill"), "phoneVideoURL": fileURL,
        "showCursor": boolean, "cursorShape": choices("arrow", "hand", "circle"), "cursorScale": number(0.5, 3),
        "zoomEnabled": ["type": "boolean", "description": "Editor Zoom master. Automatic generation uses zoomSegments omitted/nil; [] disables automatic sections. Capture Auto Zoom is a separate capture preference, not an editor setting."], "zoomLevel": number(1, 10),
        "zoomTransitionMotion": choices("smooth", "linear", "easeIn", "easeOut"),
        "zoomSegments": array(object([
            "id": uuid, "start": time, "end": time, "zoom": number(1, 10), "centerX": number(0, 1),
            "centerY": number(0, 1), "followsCursor": boolean,
            "manualRegion": object(["rect": array(array(number(0, 1), extra: ["minItems": 2, "maxItems": 2]),
                extra: ["minItems": 2, "maxItems": 2,
                        "description": "Fixed zoom area within the cropped screen, [[x,y],[width,height]], top-left origin. Width equals height, 0.125 through 1. Overrides global zoom and cursor following."])], required: ["rect"])
        ], required: ["id", "start", "end", "zoom", "centerX", "centerY", "followsCursor"])),
        "restoreAutomaticZooms": boolean,
        "webcamEnabled": boolean, "cameraMirrored": boolean, "webcamShape": choices("circle", "roundedSquare", "cutout"),
        "webcamPosition": choices("topLeft", "topCenter", "topRight", "middleLeft", "center", "middleRight", "bottomLeft", "bottomCenter", "bottomRight"),
        "webcamSize": choices("small", "medium", "large"), "videoOverlayURL": fileURL, "cameraLayout": camera,
        "faceBeautyAmount": number(0, 1),
        "cameraEffectSelection": object(["style": choices("natural", "peachMakeup"), "intensity": number(0.05, 1)],
            required: ["style", "intensity"], extra: ["description": "Exclusive camera style and remembered intensity. Preserves on/off state unless cameraEffectsEnabled is supplied. Overrides legacy faceBeautyAmount/faceMakeup.amount in the same batch."]),
        "cameraEffectsEnabled": ["type": "boolean", "description": "Enable the selected camera style, or disable it while remembering the style, intensity and makeup component settings."],
        "faceMakeup": object([
            "amount": number(0, 1), "lashes": number(0, 1), "brows": number(0, 1), "blush": number(0, 1),
            "lips": number(0, 1), "eyeshadow": number(0, 1), "underEyeShadow": number(0, 1), "aegyo": number(0, 1),
            "contour": number(0, 1), "shortening": number(0, 1), "skin": number(0, 1), "definition": number(0, 1)
        ], required: ["amount", "lashes", "brows", "blush", "lips", "eyeshadow", "aegyo", "contour", "shortening"]),
        "cameraLayoutChanges": array(object(["start": time, "settings": camera], required: ["start", "settings"])),
        "videoOverlayTiming": object(["start": time, "duration": number(0, extra: ["exclusiveMinimum": 0]), "sourceStart": time], required: ["start", "duration", "sourceStart"]),
        "voiceOvers": array(object([
            "id": uuid, "url": fileURL, "start": time, "sourceStart": time,
            "duration": number(0, extra: ["exclusiveMinimum": 0]), "sourceDuration": number(0, extra: ["exclusiveMinimum": 0])
        ], required: ["id", "url", "start", "sourceStart", "duration", "sourceDuration"])),
        "recordedAudioClips": array(mediaClip, extra: ["description": "Replaces independent recorded audio placements. Preserve existing IDs and linkIDs. Linked video clips must match the audio timing exactly; [] removes recorded audio placements."]),
        "closeTimelineGaps": boolean,
        "textOverlays": array(textOverlay, extra: ["maxItems": 100, "description": "Replaces all text layers in back-to-front order. Preserve existing IDs/objects when adding or editing; [] removes all text. Timeline rows are packed automatically and are not persisted settings."]),
        "audioEnabled": boolean, "originalAudioVolume": number(0, 1), "voiceOverEnabled": boolean, "voiceOverVolume": number(0, 1),
        "exportResolution": choices("preserveSource", "uhd4k", "fhd1080")
    ], extra: ["minProperties": 1, "description": "Partial settings batch, committed as one undo operation. Omitted top-level fields stay unchanged. Arrays replace their previous values except removeRanges. Read get_project for current values."])

    static let tools: [Schema] = {
        var retry = uuid
        retry["description"] = "Optional stable UUID for retries. Reuse it only with identical arguments. Successful mutations are deduplicated for the last 100 IDs."
        let revision: Schema = ["projectID": uuid, "expectedRevision": ["type": "integer", "minimum": 0]]
        let path: Schema = ["path": ["type": "string", "pattern": "^/", "description": "Absolute local file path."]]
        func merge(_ first: Schema, _ second: Schema) -> Schema { first.merging(second) { _, new in new } }
        let specs: [(String, String, Schema, [String], Bool, Bool)] = [
            ("get_capabilities", "List the native editor commands and revision/job requirements.", [:], [], true, false),
            ("get_project", "Read the project open in the native editor, complete settings, revision, busy state, and undo availability. Read this before editing.", [:], [], true, false),
            ("open_video", "Open local video in the native editor. When replacing a video, supply its projectID and expectedRevision; discardUnsaved=true explicitly permits replacement of unsaved work.", merge(merge(path, revision), ["discardUnsaved": boolean]), ["path"], false, true),
            ("open_project", "Open a portable .screentake project in the native editor. Replacing work has the same revision and discard requirements as open_video.", merge(merge(path, revision), ["discardUnsaved": boolean]), ["path"], false, true),
            ("save_project", "Atomically save the current editable project with embedded media to a .screentake package.", merge(path, revision), ["path", "projectID", "expectedRevision"], false, true),
            ("apply_edits", "Apply validated settings to the same draft displayed by the UI. Uses one shared undo operation. Stale revisions are rejected.", merge(revision, ["edits": edits]), ["projectID", "expectedRevision", "edits"], false, false),
            ("set_browser_toolbar_hidden", "Detect the browser content at the current preview frame and crop away its toolbar, or restore the previous crop. Uses the native editor control and shared Undo history.", merge(revision, ["hidden": boolean]), ["projectID", "expectedRevision", "hidden"], false, false),
            ("find_silences", "Analyze original audio or an added audio track. Default suggestions use source seconds; audioTrackID or outputTime=true returns edited-video seconds. Check job.suggestionTimebase and apply with removeRanges or removeOutputRanges respectively.", merge(revision, ["silence": object(["thresholdDB": number(-80, 0), "minimumPause": number(0, extra: ["exclusiveMinimum": 0]), "padding": time], required: ["thresholdDB", "minimumPause", "padding"]), "audioTrackID": uuid, "outputTime": boolean]), ["projectID", "expectedRevision"], false, false),
            ("render_preview", "Start a preview job at 1–12 edited-video timestamps. Poll get_job, then call get_preview_frame to see a PNG.", merge(revision, ["times": array(time, extra: ["minItems": 1, "maxItems": 12])]), ["projectID", "expectedRevision"], false, false),
            ("export_video", "Start a job rendering the current draft and atomically saving video to the destination. Poll get_job; cancel_job can stop encoding and preserve an existing destination.", merge(path, revision), ["path", "projectID", "expectedRevision"], false, true),
            ("get_job", "Read queued/running/cancelling/succeeded/failed/cancelled status, progress, output, preview frame indices, or silence suggestions. The last 50 jobs are retained.", ["jobID": uuid], ["jobID"], true, false),
            ("cancel_job", "Request cancellation of a known job. Poll get_job until teardown reaches a terminal state.", ["jobID": uuid], ["jobID"], false, false),
            ("undo", "Undo the last settings change made by either the UI or a tool.", revision, ["projectID", "expectedRevision"], false, false),
            ("redo", "Redo a settings change from the shared history.", revision, ["projectID", "expectedRevision"], false, false),
            ("get_preview_frame", "Return a PNG image from a completed render_preview job, scaled to at most 1024 pixels per side. No arbitrary file reads.", ["jobID": uuid, "index": ["type": "integer", "minimum": 0]], ["jobID", "index"], true, false)
        ]
        return specs.map { name, description, properties, required, readOnly, destructive in
            ["name": name, "description": description, "inputSchema": object(merge(properties, ["requestID": retry]), required: required),
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive,
                             "idempotentHint": readOnly || name == "cancel_job", "openWorldHint": false]]
        }
    }()
}
