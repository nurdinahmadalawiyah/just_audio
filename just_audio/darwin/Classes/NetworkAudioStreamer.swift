import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

protocol NetworkAudioStreamerDelegate: AnyObject {
    func streamer(_ streamer: NetworkAudioStreamer, didDecodeBuffer buffer: AVAudioPCMBuffer)
    func streamerDidFinishDecoding(_ streamer: NetworkAudioStreamer)
    func streamer(_ streamer: NetworkAudioStreamer, didFailWithError error: Error)
}

class NetworkAudioStreamer: NSObject, URLSessionDataDelegate {
    
    weak var delegate: NetworkAudioStreamerDelegate?
    let url: URL
    
    private var session: URLSession!
    private var dataTask: URLSessionDataTask?
    
    private var streamID: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var inputFormat = AudioStreamBasicDescription()
    private var isPlaying = false
    
    private var packetData = [Data]()
    private var packetDescriptions = [AudioStreamPacketDescription]()
    
    private let outputFormat: AVAudioFormat
    
    init(url: URL) {
        self.url = url
        // Default output to standard PCM buffer format
        self.outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: DispatchQueue(label: "NetworkAudioStreamerQueue"))
    }
    
    func start() {
        dataTask = session.dataTask(with: url)
        dataTask?.resume()
        isPlaying = true
    }
    
    func stop() {
        dataTask?.cancel()
        isPlaying = false
        if let stream = streamID {
            AudioFileStreamClose(stream)
            streamID = nil
        }
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if streamID == nil {
            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            AudioFileStreamOpen(context, propertyListenerProc, packetsProc, 0, &streamID)
        }
        
        data.withUnsafeBytes { rawBuffer in
            if let ptr = rawBuffer.baseAddress {
                AudioFileStreamParseBytes(streamID!, UInt32(data.count), ptr, 0)
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            delegate?.streamer(self, didFailWithError: error)
        } else {
            delegate?.streamerDidFinishDecoding(self)
        }
    }
    
    // MARK: - AudioFileStream Callbacks
    
    private let propertyListenerProc: AudioFileStream_PropertyListenerProc = { context, streamID, propertyID, flags in
        let streamer = Unmanaged<NetworkAudioStreamer>.fromOpaque(context).takeUnretainedValue()
        streamer.handlePropertyListener(streamID: streamID, propertyID: propertyID)
    }
    
    private let packetsProc: AudioFileStream_PacketsProc = { context, byteCount, packetCount, data, packetDescriptions in
        let streamer = Unmanaged<NetworkAudioStreamer>.fromOpaque(context).takeUnretainedValue()
        streamer.handlePackets(byteCount: byteCount, packetCount: packetCount, data: data, packetDescriptions: packetDescriptions)
    }
    
    private func handlePropertyListener(streamID: AudioFileStreamID, propertyID: AudioFileStreamPropertyID) {
        if propertyID == kAudioFileStreamProperty_DataFormat {
            var formatListSize: UInt32 = 0
            AudioFileStreamGetPropertyInfo(streamID, kAudioFileStreamProperty_DataFormat, &formatListSize, nil)
            var format = AudioStreamBasicDescription()
            AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &formatListSize, &format)
            self.inputFormat = format
            
            var destFormat = outputFormat.streamDescription.pointee
            AudioConverterNew(&self.inputFormat, &destFormat, &self.converter)
        }
    }
    
    // A simplified conversion using AudioConverter
    private func handlePackets(byteCount: UInt32, packetCount: UInt32, data: UnsafeRawPointer, packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let pDescriptions = packetDescriptions, let converter = self.converter else { return }
        
        let ptr = data.bindMemory(to: UInt8.self, capacity: Int(byteCount))
        
        for i in 0..<Int(packetCount) {
            let desc = pDescriptions[i]
            let packetData = Data(bytes: ptr.advanced(by: Int(desc.mStartOffset)), count: Int(desc.mDataByteSize))
            self.packetData.append(packetData)
            self.packetDescriptions.append(desc)
        }
        
        // When we have enough packets, try to convert them
        if self.packetData.count >= 20 { // Process in batches
            convertPackets()
        }
    }
    
    private func convertPackets() {
        guard let converter = self.converter else { return }
        let packetCount = UInt32(packetData.count)
        guard packetCount > 0 else { return }
        
        // Set up output buffer
        let outputFrames: UInt32 = 4096
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrames)!
        
        var framesToConvert = outputFrames
        
        var contextInfo = DecoderContext(streamer: self)
        let status = AudioConverterFillComplexBuffer(converter, complexInputDataProc, &contextInfo, &framesToConvert, pcmBuffer.mutableAudioBufferList, nil)
        
        if status == noErr && framesToConvert > 0 {
            pcmBuffer.frameLength = framesToConvert
            DispatchQueue.main.async {
                self.delegate?.streamer(self, didDecodeBuffer: pcmBuffer)
            }
        }
    }
    
    // MARK: - Decoder Context
    
    struct DecoderContext {
        var streamer: NetworkAudioStreamer
    }
    
    private let complexInputDataProc: AudioConverterComplexInputDataProc = { converter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
        let context = inUserData?.bindMemory(to: DecoderContext.self, capacity: 1).pointee
        guard let streamer = context?.streamer else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        
        if streamer.packetData.isEmpty {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        
        let data = streamer.packetData.removeFirst()
        let desc = streamer.packetDescriptions.removeFirst()
        
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: (data as NSData).bytes)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(data.count)
        
        if let outDesc = outDataPacketDescription {
            outDesc.pointee = desc
            outDesc.pointee.mStartOffset = 0
        }
        
        ioNumberDataPackets.pointee = 1
        return noErr
    }
}
