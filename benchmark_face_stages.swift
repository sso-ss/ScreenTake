import AppKit
import AVFoundation
import CoreImage
import Vision

/// Build with production filter/detector and benchmark_face_mesh.swift, -O,
/// -D FACE_BEAUTY_PROFILING and -D FACE_BEAUTY_STAGE_BENCHMARK. Profiling hooks
/// are excluded entirely from ordinary app builds.
@main struct FaceStageBenchmark {
    static func main() async throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count >= 3 else {
            print("Usage: FaceStageBenchmark CAMERA.mov OUTPUT_DIRECTORY [PROJECT.json]")
            return
        }
        let video = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var makeup = FaceMakeupSettings(amount: 1)
        if CommandLine.arguments.count > 3 {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
            let settings = json["settings"] as! [String: Any]
            makeup = try JSONDecoder().decode(FaceMakeupSettings.self,
                from: JSONSerialization.data(withJSONObject: settings["faceMakeup"]!))
            makeup.amount = 1
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        var stageTimes: [String: [String: [Double]]] = [:]
        var totals: [String: [Double]] = [:], runs: [[String: Any]] = []
        // Reversed resolution order reduces consistent startup/order bias.
        for (round, edge) in [CGFloat(640), 960, 960, 640].enumerated() {
            let key = String(Int(edge))
            let filter = FaceBeautyFilter()
            let (reader, output, transform) = try await FaceMeshBenchmark.reader(video)
            var frame = 0, faces = 0, meshes = 0, handFrames = 0, runTimes: [Double] = []
            while let buffer = output.copyNextSampleBuffer() {
                autoreleasepool {
                    let source = FaceMeshBenchmark.image(buffer, transform: transform, edge: edge)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = filter.render(source, at: CMSampleBufferGetPresentationTimeStamp(buffer).seconds,
                                               amount: 0, makeup: makeup)
                    let renderStart = DispatchTime.now().uptimeNanoseconds
                    _ = context.createCGImage(result, from: result.extent)
                    let gpuMs = FaceMeshBenchmark.milliseconds(renderStart)
                    let totalMs = FaceMeshBenchmark.milliseconds(start)
                    if frame >= 12, let profile = filter.lastProfile {
                        for (stage, ms) in profile.stagesMs { stageTimes[key, default: [:]][stage, default: []].append(ms) }
                        stageTimes[key, default: [:]]["output.render", default: []].append(gpuMs)
                        let measured = profile.stagesMs.values.reduce(0,+) + gpuMs
                        stageTimes[key, default: [:]]["overhead", default: []].append(max(0,totalMs-measured))
                        totals[key, default: []].append(totalMs)
                        runTimes.append(totalMs)
                    }
                    if filter.lastDetectedGeometry != nil { faces += 1 }
                    if filter.lastDetectedGeometry?.mesh != nil { meshes += 1 }
                    if !filter.lastDetectedHands.isEmpty { handFrames += 1 }
                    frame += 1
                }
            }
            guard reader.status == .completed else { throw reader.error! }
            runs.append(["round": round + 1, "edge": Int(edge), "frames": frame, "faces": faces,
                "meshes": meshes, "framesWithHands": handFrames, "timing": FaceMeshBenchmark.summary(runTimes)])
            print("Production stages \(Int(edge))px round \(round+1): \(FaceMeshBenchmark.summary(runTimes)); faces=\(faces), meshes=\(meshes), handFrames=\(handFrames)")
        }
        var production: [String: Any] = [:]
        for key in stageTimes.keys.sorted() {
            let meanTotal = totals[key]!.reduce(0,+)/Double(totals[key]!.count)
            var stages: [String: Any] = [:]
            for (stage, values) in stageTimes[key]! {
                var stats = FaceMeshBenchmark.summary(values)
                stats["meanSharePercent"] = stats["meanMs"]! / meanTotal * 100
                stages[stage] = stats
            }
            production[key] = ["total": FaceMeshBenchmark.summary(totals[key]!), "stages": stages]
            let means: [(String, [Double], Double)] = stageTimes[key]!.map { entry in
                let mean = entry.value.reduce(0,+)/Double(entry.value.count)
                return (entry.key,entry.value,mean)
            }
            let ordered = means.sorted { $0.2 > $1.2 }
            for (stage, values, _) in ordered.prefix(8) {
                print("\(key)px \(stage): \(FaceMeshBenchmark.summary(values))")
            }
        }

        // Standalone requests explain face/hand costs, but their sum is not a
        // decomposition of the production batch: Vision can share preprocessing.
        var standalone: [String: Any] = [:], renderProbes: [String: Any] = [:]
        for edge: CGFloat in [640, 960] {
            let (reader, output, transform) = try await FaceMeshBenchmark.reader(video)
            var samples: [(CIImage, Double)] = [], frame = 0
            while let buffer = output.copyNextSampleBuffer() {
                if frame % 12 == 6 {
                    autoreleasepool {
                        let source = FaceMeshBenchmark.image(buffer, transform: transform, edge: edge)
                        samples.append((CIImage(cgImage: context.createCGImage(source, from: source.extent)!),
                                        CMSampleBufferGetPresentationTimeStamp(buffer).seconds))
                    }
                }
                frame += 1
            }
            guard reader.status == .completed else { throw reader.error! }
            let names = ["faces", "hands", "pose", "faceAndHandBatch"]
            var requestTimes: [String: [Double]] = [:]
            for round in 0..<5 {
                for (sample, _) in samples {
                    let order = round % 2 == 0 ? names : Array(names.reversed())
                    for name in order {
                        try autoreleasepool {
                            let faces = VNDetectFaceLandmarksRequest()
                            let hands = VNDetectHumanHandPoseRequest(); hands.maximumHandCount = 2
                            let pose = VNDetectFaceRectanglesRequest(); pose.revision = VNDetectFaceRectanglesRequestRevision3
                            let requests: [VNRequest]
                            switch name {
                            case "faces": requests = [faces]
                            case "hands": requests = [hands]
                            case "pose": requests = [pose]
                            default: requests = [faces, hands]
                            }
                            let start = DispatchTime.now().uptimeNanoseconds
                            try VNImageRequestHandler(ciImage: sample, options: [:]).perform(requests)
                            if round > 0 { requestTimes[name, default: []].append(FaceMeshBenchmark.milliseconds(start)) }
                        }
                    }
                }
            }
            standalone[String(Int(edge))] = requestTimes.mapValues { FaceMeshBenchmark.summary($0) }
            print("Standalone Vision \(Int(edge))px: \(requestTimes.mapValues { FaceMeshBenchmark.summary($0) })")

            // These are independent graph renders including all dependencies.
            // Do not add/subtract them as stage costs: barriers/caches/fusion
            // differ from one uninterrupted output render in production.
            let filter = FaceBeautyFilter()
            filter.profileImagesEnabled = true
            var graphTimes: [String: [Double]] = [:]
            for (index, sample) in samples.enumerated() {
                autoreleasepool {
                    _ = filter.render(sample.0, at: sample.1, amount: 0, makeup: makeup)
                    guard let profile = filter.lastProfile else { return }
                    for name in ["handMask", "surfaceMask", "shapingMask", "skinMask", "skinOutput", "makeupOutput", "final"] {
                        guard let graph = profile.images[name] else { continue }
                        let start = DispatchTime.now().uptimeNanoseconds
                        _ = context.createCGImage(graph, from: graph.extent)
                        if index >= 3 { graphTimes[name, default: []].append(FaceMeshBenchmark.milliseconds(start)) }
                    }
                }
            }
            renderProbes[String(Int(edge))] = graphTimes.mapValues { FaceMeshBenchmark.summary($0) }
        }
        let report: [String: Any] = ["production": production, "runs": runs,
            "standaloneVision": standalone, "independentGraphRenderProbes": renderProbes,
            "method": "Optimized production sources; actual face/hand batch preserved; first 12 frames excluded from steady-state timings; deferred output render measured separately; profiling hooks compile out of normal app. Standalone Vision costs and independent graph probes are diagnostic and not additive. Recorded replay does not measure live-recording contention, power, thermals or dropped capture frames."]
        let outputURL = directory.appendingPathComponent("results.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL)
        print("Saved \(outputURL.path)")
    }
}
