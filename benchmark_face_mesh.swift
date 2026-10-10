import AppKit
import AVFoundation
import CoreImage
import CoreML

/// Compare compute units on an existing camera clip. Build with the production
/// DenseFaceMesh.swift and FaceBeautyFilter.swift, using -O. The executable's
/// bundle needs FaceMesh.mlmodelc and triangles.json in Contents/Resources.
#if !FACE_BEAUTY_STAGE_BENCHMARK
@main
#endif
struct FaceMeshBenchmark {
    struct Mode {
        let name: String
        let units: MLComputeUnits
    }
    struct Input {
        let image: CIImage
        let face: FaceBeautyGeometry
    }
    static let modes = [Mode(name: "cpuAndGPU", units: .cpuAndGPU), Mode(name: "all", units: .all)]

    static func milliseconds(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func summary(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [:] }
        return ["medianMs": sorted[sorted.count / 2],
                "p95Ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                "meanMs": values.reduce(0, +) / Double(values.count)]
    }
    static func reader(_ url: URL) async throws -> (AVAssetReader, AVAssetReaderTrackOutput, CGAffineTransform) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let transform = try await track.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        return (reader, output, transform)
    }
    static func image(_ buffer: CMSampleBuffer, transform: CGAffineTransform, edge: CGFloat) -> CIImage {
        let source = CIImage(cvPixelBuffer: CMSampleBufferGetImageBuffer(buffer)!).transformed(by: transform)
        let upright = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let scale = min(1, edge / max(upright.extent.width, upright.extent.height))
        return upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    static func pixels(_ image: CIImage, context: CIContext) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: image.extent,
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }

    static func main() async throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count >= 3 else {
            print("Usage: FaceMeshBenchmark CAMERA.mov OUTPUT_DIRECTORY [PROJECT.json]")
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
        let sparse = FaceBeautyFilter(meshEnabled: false)
        let (inputReader, inputOutput, transform) = try await reader(video)
        var inputs: [Input] = [], index = 0
        while let buffer = inputOutput.copyNextSampleBuffer() {
            if index % 9 == 0 {
                autoreleasepool {
                    let decoded = image(buffer, transform: transform, edge: 960)
                    // Retain only sampled, resized rasters rather than the full
                    // resolution decoder buffers for the complete recording.
                    let raster = CIImage(cgImage: context.createCGImage(decoded, from: decoded.extent)!)
                    _ = sparse.render(raster, at: CMSampleBufferGetPresentationTimeStamp(buffer).seconds,
                                      amount: 0, makeup: makeup)
                    if let face = sparse.lastDetectedGeometry { inputs.append(Input(image: raster, face: face)) }
                }
            }
            index += 1
        }
        guard inputReader.status == .completed, !inputs.isEmpty else {
            throw inputReader.error ?? NSError(domain: "Benchmark", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No current faces in camera clip"])
        }
        print("Loaded \(inputs.count) face samples from \(index) camera frames")
        var report: [String: Any] = ["cameraFrames": index, "sampledFaces": inputs.count,
            "makeupAmount": makeup.amount, "method": "Optimized build; identical frames; warmup excluded; alternating inference and ABBA full-filter order. No power measurement or proof of Neural Engine execution."]
        var detectors: [String: DenseFaceMeshDetector] = [:], loads: [String: Double] = [:]
        for mode in modes {
            let start = DispatchTime.now().uptimeNanoseconds
            let detector = DenseFaceMeshDetector(computeUnits: mode.units)
            loads[mode.name] = milliseconds(start)
            guard detector.error == nil else { throw NSError(domain: "Benchmark", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(mode.name): \(detector.error!)"]) }
            detectors[mode.name] = detector
            for _ in 0..<12 {
                guard detector.detect(inputs[0].image, face: inputs[0].face) != nil else {
                    throw NSError(domain: "Benchmark", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "\(mode.name) warmup failed: \(detector.error ?? "mesh rejected")"])
                }
            }
        }
        var timings: [String: [Double]] = [:], failures: [String: Int] = [:]
        var referenceMeshes: [Int: DenseFaceMesh] = [:]
        var pointDistances: [Double] = [], confidenceDifference = 0.0
        for round in 0..<8 {
            for (sample, input) in inputs.enumerated() {
                let order = (round + sample) % 2 == 0 ? modes : Array(modes.reversed())
                for mode in order {
                    autoreleasepool {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let mesh = detectors[mode.name]!.detect(input.image, face: input.face)
                        timings[mode.name, default: []].append(milliseconds(start))
                        guard let mesh else { failures[mode.name, default: 0] += 1; return }
                        if mode.name == "cpuAndGPU" { referenceMeshes[sample] = mesh }
                        if mode.name == "all", let reference = referenceMeshes[sample] {
                            confidenceDifference = max(confidenceDifference, abs(mesh.confidence - reference.confidence))
                            for (a, b) in zip(mesh.points, reference.points) {
                                let x = Double(a.x - b.x) * input.image.extent.width
                                let y = Double(a.y - b.y) * input.image.extent.height
                                let z = Double(a.z - b.z) * input.image.extent.width
                                pointDistances.append(sqrt(x*x + y*y + z*z))
                            }
                        }
                    }
                }
            }
        }
        var meshReport: [String: Any] = [:]
        for mode in modes {
            let stats = summary(timings[mode.name]!)
            meshReport[mode.name] = ["timing": stats, "calls": timings[mode.name]!.count,
                "failures": failures[mode.name, default: 0], "modelLoadMs": loads[mode.name]!]
            print("Mesh \(mode.name): \(stats), failures=\(failures[mode.name, default: 0])")
        }
        report["mesh"] = meshReport
        report["meshDifference"] = ["meanPointDistancePx": pointDistances.reduce(0,+)/Double(max(1,pointDistances.count)),
            "maxPointDistancePx": pointDistances.max() ?? 0, "maxConfidenceDifference": confidenceDifference]
        var pipeline: [String: Any] = [:]
        for edge: CGFloat in [640, 960] {
            var aggregate: [String: [Double]] = [:], runs: [[String: Any]] = []
            var referencePixels: [Int: [UInt8]] = [:]
            var pixelError = 0.0, pixelCount = 0, maxPixelError = 0
            for (round, mode) in [modes[0], modes[1], modes[1], modes[0]].enumerated() {
                let filter = FaceBeautyFilter(meshComputeUnits: mode.units)
                for warmup in 0..<12 {
                    let result = filter.render(inputs[0].image, at: Double(warmup)/30, amount: 0, makeup: makeup)
                    _ = context.createCGImage(result, from: result.extent)
                }
                let (reader, output, transform) = try await reader(video)
                var frame = 0, detected = 0, meshed = 0, durations: [Double] = []
                while let buffer = output.copyNextSampleBuffer() {
                    autoreleasepool {
                        let source = image(buffer, transform: transform, edge: edge)
                        let start = DispatchTime.now().uptimeNanoseconds
                        let result = filter.render(source, at: CMSampleBufferGetPresentationTimeStamp(buffer).seconds,
                                                   amount: 0, makeup: makeup)
                        _ = context.createCGImage(result, from: result.extent)
                        let elapsed = milliseconds(start)
                        // Startup/seek behavior is checked but excluded from
                        // steady-state statistics equally for both modes.
                        if frame >= 12 { durations.append(elapsed) }
                        if filter.lastDetectedGeometry != nil { detected += 1 }
                        if filter.lastDetectedGeometry?.mesh != nil { meshed += 1 }
                        if frame % 30 == 0 {
                            let bytes = pixels(result, context: context)
                            if round == 0 { referencePixels[frame] = bytes }
                            if round == 1, let reference = referencePixels[frame], reference.count == bytes.count {
                                for (a, b) in zip(bytes, reference) {
                                    let error = abs(Int(a) - Int(b))
                                    pixelError += Double(error); pixelCount += 1; maxPixelError = max(maxPixelError,error)
                                }
                            }
                        }
                        frame += 1
                    }
                }
                guard reader.status == .completed else { throw reader.error! }
                aggregate[mode.name, default: []].append(contentsOf: durations)
                runs.append(["mode": mode.name, "frames": frame, "detected": detected,
                    "meshes": meshed, "timing": summary(durations)])
                print("Full filter \(Int(edge))px round \(round+1) \(mode.name): \(summary(durations)), faces=\(detected), meshes=\(meshed)")
            }
            pipeline[String(Int(edge))] = ["cpuAndGPU": summary(aggregate["cpuAndGPU"]!),
                "all": summary(aggregate["all"]!), "runs": runs,
                "renderDifference": ["meanByteDifference": pixelError/Double(max(1,pixelCount)), "maxByteDifference": maxPixelError]]
        }
        report["fullFilter"] = pipeline
        let outputURL = directory.appendingPathComponent("results.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL)
        print("Saved \(outputURL.path)")
    }
}
