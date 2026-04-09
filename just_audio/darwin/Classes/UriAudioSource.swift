

import Foundation
import CoreMedia
import AVFoundation

class UriAudioSource: IndexedAudioSource, NetworkAudioStreamerDelegate {
    var url: URL
    var duration: CMTime = .invalid
    var streamer: NetworkAudioStreamer?
    var onPlayerLoaded: (() -> Void)?
    weak var currentPlayerNode: AVAudioPlayerNode?

    init(sid: String, uri: String) {
        url = UriAudioSource.urlFrom(uri: uri)

        super.init(sid: sid)
    }

    override func load(engine _: AVAudioEngine, playerNode: AVAudioPlayerNode, speedControl _: AVAudioUnitVarispeed, position: CMTime?, completionHandler: @escaping () -> Void) throws {
        self.onPlayerLoaded = completionHandler
        self.currentPlayerNode = playerNode
        
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            streamer = NetworkAudioStreamer(url: url)
            streamer?.delegate = self
            streamer?.start()
        } else {
            let audioFile = try! AVAudioFile(forReading: url)
            let audioFormat = audioFile.fileFormat

            duration = UriAudioSource.durationFrom(audioFile: audioFile)
            let sampleRate = audioFormat.sampleRate

            if let position = position, position.seconds > 0 {
                let framePosition = AVAudioFramePosition(sampleRate * position.seconds)

                let missingTime = duration.seconds - position.seconds
                let framesToPlay = AVAudioFrameCount(sampleRate * missingTime)

                if framesToPlay > 1000 {
                    playerNode.scheduleSegment(audioFile, startingFrame: framePosition, frameCount: framesToPlay, at: nil, completionHandler: completionHandler)
                }
            } else {
                playerNode.scheduleFile(audioFile, at: nil, completionHandler: completionHandler)
            }
        }
    }
    
    // MARK: NetworkAudioStreamerDelegate
    
    func streamer(_ streamer: NetworkAudioStreamer, didDecodeBuffer buffer: AVAudioPCMBuffer) {
        guard let playerNode = currentPlayerNode else { return }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        
        // If this is the first buffer, trigger the completion handler so player logic can proceed
        if self.onPlayerLoaded != nil {
            DispatchQueue.main.async {
                self.onPlayerLoaded?()
                self.onPlayerLoaded = nil
            }
        }
    }
    
    func streamerDidFinishDecoding(_ streamer: NetworkAudioStreamer) {
        // Nothing special. Buffer schedule handles the end.
    }
    
    func streamer(_ streamer: NetworkAudioStreamer, didFailWithError error: Error) {
        print("Streamer error: \(error)")
    }

    override func getDuration() -> CMTime {
        return duration
    }
    
    override func stop() {
        streamer?.stop()
        streamer = nil
    }

    static func durationFrom(audioFile: AVAudioFile) -> CMTime {
        let seconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        return CMTime(value: Int64(seconds * 1000), timescale: 1000)
    }

    static func urlFrom(uri: String) -> URL {
        if uri.hasPrefix("ipod-library://") || uri.hasPrefix("file://") {
            return URL(string: uri)!
        } else {
            return URL(fileURLWithPath: uri)
        }
    }
}
