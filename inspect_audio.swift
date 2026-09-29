import AVFoundation
import Foundation

@main
struct InspectAudio {
    static func main() async throws {
        for path in CommandLine.arguments.dropFirst() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let duration = try await asset.load(.duration)
            print("FILE \(path) duration=\(duration.seconds)")
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let range = try await track.load(.timeRange)
                let formats = try await track.load(.formatDescriptions)
                print("TRACK \(track.trackID) start=\(range.start.seconds) duration=\(range.duration.seconds)")
                for format in formats {
                    if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                        print("FORMAT \(description.pointee)")
                    }
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false
                ])
                reader.add(output)
                guard reader.startReading() else { throw reader.error! }
                var buffers = 0
                var frames = 0
                var count = 0
                var clipped = 0
                var nonfinite = 0
                var peak: Float = 0
                var energy: Double = 0
                var lastEnd: Double = 0
                var gaps = 0
                while let sample = output.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    let duration = CMSampleBufferGetDuration(sample).seconds
                    if buffers < 4 { print("BUFFER frames=\(CMSampleBufferGetNumSamples(sample)) pts=\(pts) duration=\(duration)") }
                    if buffers > 0 && abs(pts - lastEnd) > 0.001 { gaps += 1 }
                    lastEnd = pts + duration
                    buffers += 1
                    frames += CMSampleBufferGetNumSamples(sample)
                    if let block = CMSampleBufferGetDataBuffer(sample) {
                        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
                        let copyStatus = values.withUnsafeMutableBytes { bytes in
                            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                        }
                        guard copyStatus == noErr else { continue }
                        for value in values {
                            count += 1
                            if !value.isFinite { nonfinite += 1; continue }
                            peak = max(peak, abs(value))
                            if abs(value) >= 0.999 { clipped += 1 }
                            energy += Double(value) * Double(value)
                        }
                    }
                }
                print("RESULT buffers=\(buffers) frames=\(frames) end=\(lastEnd) gaps=\(gaps) peak=\(peak) rms=\(sqrt(energy / Double(max(1, count)))) clipped=\(clipped)/\(count) nonfinite=\(nonfinite) status=\(reader.status.rawValue) error=\(String(describing: reader.error))")
            }
        }
    }
}