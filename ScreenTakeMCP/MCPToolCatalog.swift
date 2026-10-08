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
    static let exactRange = object([
        "startValue": ["type": "integer", "minimum": 0], "startScale": ["type": "integer", "minimum": 1],
        "durationValue": ["type": "integer", "minimum": 1], "durationScale": ["type": "integer", "minimum": 1]
    ], required: ["startValue", "startScale", "durationValue", "durationScale"])
    static let camera = object([
        "layout": choices("overlay", "fullScreen"), "zoom": number(1, 3), "centerX": number(0, 1), "centerY": number(0, 1),
        "followFace": boolean, "smoothTransition": boolean, "transitionDuration": number(0.1, 2),
        "transitionMotion": choices("smooth", "linear", "easeIn", "easeOut")
    ], extra: ["description": "Replaces camera framing; omitted members use native defaults."])

    static let edits = object([
        "trim": object(["start": time, "end": ["type": ["number", "null"], "minimum": 0], "cuts": array(cut),
                        "splits": array(time), "clipOrder": array(exactRange)],
                       extra: ["description": "Replaces the timeline. Seconds refer to source time; clipOrder preserves rational CMTime ranges."]),
        "removeRanges": array(cut, extra: ["description": "Append cuts in source seconds. Supply a UUID for each cut."]),
        "ratio": choices("original", "landscape", "desktop", "square", "portrait", "vertical"),
        "layout": choices("desktop", "iPhone", "duo", "iPhoneDuoClosed", "iPhoneDuoUnfolded"),
        "wallpaper": choices("sonoma", "aurora", "sunset", "ocean", "blossom", "nebula", "moss", "dusk", "prism", "lagoon", "ember", "midnight"),
        "backgroundEnabled": boolean, "desktopCornerRadius": number(0, 0.5),
        "crop": object(["rect": array(array(number(0, 1), extra: ["minItems": 2, "maxItems": 2]),
                                       extra: ["minItems": 2, "maxItems": 2, "description": "CGRect encoded as [[x,y],[width,height]], normalized to source dimensions."])], required: ["rect"]),
        "phoneMode": choices("fit", "fill"), "phoneVideoURL": fileURL,
        "showCursor": boolean, "cursorShape": choices("arrow", "hand", "circle"), "cursorScale": number(0.5, 3),
        "zoomEnabled": boolean, "zoomLevel": number(1, 10),
        "zoomSegments": array(object([
            "id": uuid, "start": time, "end": time, "zoom": number(1, 10), "centerX": number(0, 1),
            "centerY": number(0, 1), "followsCursor": boolean
        ], required: ["id", "start", "end", "zoom", "centerX", "centerY", "followsCursor"])),
        "restoreAutomaticZooms": boolean,
        "webcamEnabled": boolean, "webcamShape": choices("circle", "roundedSquare"),
        "webcamPosition": choices("topLeft", "topCenter", "topRight", "middleLeft", "center", "middleRight", "bottomLeft", "bottomCenter", "bottomRight"),
        "webcamSize": choices("small", "medium", "large"), "videoOverlayURL": fileURL, "cameraLayout": camera,
        "cameraLayoutChanges": array(object(["start": time, "settings": camera], required: ["start", "settings"])),
        "videoOverlayTiming": object(["start": time, "duration": number(0, extra: ["exclusiveMinimum": 0]), "sourceStart": time], required: ["start", "duration", "sourceStart"]),
        "voiceOvers": array(object([
            "id": uuid, "url": fileURL, "start": time, "sourceStart": time,
            "duration": number(0, extra: ["exclusiveMinimum": 0]), "sourceDuration": number(0, extra: ["exclusiveMinimum": 0])
        ], required: ["id", "url", "start", "sourceStart", "duration", "sourceDuration"])),
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
            ("open_project", "Open a portable .screenize project in the native editor. Replacing work has the same revision and discard requirements as open_video.", merge(merge(path, revision), ["discardUnsaved": boolean]), ["path"], false, true),
            ("save_project", "Atomically save the current editable project with embedded media to a .screenize package.", merge(path, revision), ["path", "projectID", "expectedRevision"], false, true),
            ("apply_edits", "Apply validated settings to the same draft displayed by the UI. Uses one shared undo operation. Stale revisions are rejected.", merge(revision, ["edits": edits]), ["projectID", "expectedRevision", "edits"], false, false),
            ("find_silences", "Start an analysis job suggesting removals in retained source time. Suggestions do not change the timeline; review and apply them with apply_edits.", merge(revision, ["silence": object(["thresholdDB": number(-80, 0), "minimumPause": number(0, extra: ["exclusiveMinimum": 0]), "padding": time], required: ["thresholdDB", "minimumPause", "padding"])]), ["projectID", "expectedRevision"], false, false),
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
