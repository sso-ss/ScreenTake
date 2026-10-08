import AppKit
import AVFoundation
import Darwin

@main
struct EditorMCPChecks {
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: "/tmp/sct-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.mov")
        try await fixture(source)
        let session = EditorSession()
        let commands = EditorCommandDispatcher(session: session)
        let path = directory.appendingPathComponent("editor.sock").path
        let server = try EditorSocketTransport(path: path) { data in
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["artifact"] as? String == "preview_frame",
               let id = object["jobID"] as? String, let uuid = UUID(uuidString: id), let index = object["index"] as? Int {
                return await commands.previewFrameJSON(jobID: uuid, index: index)
            }
            return await commands.executeJSON(data)
        }
        defer { server.stop() }
        do {
            _ = try EditorSocketTransport(path: path) { _ in Data() }
            preconditionFailure("Second server stole active socket")
        } catch { }
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        test.arguments = ["test_mcp_bridge.py", "--socket", path, "--source", source.path, "--destination", directory.path]
        try test.run()
        while test.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(test.terminationStatus == 0, "MCP integration failed")
        precondition(session.draft.ratio == .square && session.draft.trim.end == 1.5 && session.canUndo == false)
        let export = AVURLAsset(url: directory.appendingPathComponent("Export.mov"))
        let duration = try await export.load(.duration).seconds
        precondition(abs(duration - 1.5) < 0.002)
        let image = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent("Preview.png")))!
        let color = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        precondition(color.redComponent > 0.8 && color.greenComponent < 0.2, "MCP returned incorrect preview pixels")
        server.stop()
        precondition(!FileManager.default.fileExists(atPath: path))
        // Recovery after a crash leaves a stale socket, but never permits deleting
        // an arbitrary file or following a replaced connection directory.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(stale >= 0)
        let address = try EditorSocketTransport.address(path)
        precondition(EditorSocketTransport.withAddress(address) { bind(stale, $0, $1) } == 0)
        close(stale)
        let recovered = try EditorSocketTransport(path: path) { _ in Data("{}".utf8) }
        recovered.stop()
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        do {
            _ = try EditorSocketTransport(path: path) { _ in Data() }
            preconditionFailure("Unexpected file was removed")
        } catch { }
        let preserved = try String(contentsOfFile: path)
        precondition(preserved == "keep")
        try FileManager.default.removeItem(atPath: path)
        let alias = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        do {
            _ = try EditorSocketTransport(path: alias.appendingPathComponent("editor.sock").path) { _ in Data() }
            preconditionFailure("Symlink directory accepted")
        } catch { }
        print("PASS: socket ownership, shutdown/restart, stale recovery, file/symlink preservation, native state, exported duration, and preview pixels")
    }

    static func fixture(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, nil, &buffer)
            context.render(CIImage(color: .red), to: buffer!)
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: EditorAudio.time(2))
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }
}
