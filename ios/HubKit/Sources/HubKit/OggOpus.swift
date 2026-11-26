import AVFoundation
import Foundation

/// WhatsApp's voice notes: Ogg Opus. iOS decodes Ogg Opus files itself (AVAudioFile) and encodes Opus packets
/// (AVAudioConverter), but writes no Ogg: `ogg` puts the packets in pages (RFC 7845: OpusHead, OpusTags, then
/// the audio, granule positions in 48 kHz samples).
public enum OggOpus {
    /// 20 ms packets at 48 kHz.
    static let frames = 960
    /// The encoder's lookahead the player skips (libopus's at 48 kHz).
    static let preSkip = 312

    public enum Failure: Error { case encoder, decode }

    /// Mono samples at `rate` → an Ogg Opus file (voice, ~24 kbit/s).
    public static func encode(_ samples: [Float], rate: Double) throws -> Data {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else { throw Failure.encoder }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd), let conv = AVAudioConverter(from: pcm, to: opus),
              let src = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { throw Failure.encoder }
        conv.bitRate = 24000
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var given = false
        var packets: [Data] = []
        while true {
            let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 32, maximumPacketSize: max(conv.maximumOutputPacketSize, 1500))
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, st in
                if given { st.pointee = .endOfStream; return nil }
                given = true
                st.pointee = .haveData
                return src
            }
            if status == .error { throw err ?? Failure.encoder }
            for k in 0..<Int(out.packetCount) {
                let d = out.packetDescriptions![k]
                packets.append(Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
            }
            if status == .endOfStream || out.packetCount == 0 { break }
        }
        guard !packets.isEmpty else { throw Failure.encoder }
        let length = Int((Double(samples.count) * 48000 / rate).rounded())
        return ogg(packets, inputRate: Int(rate), length: length)
    }

    /// The packets (each `frames` long) as an Ogg Opus file; `length`: the audio's samples at 48 kHz (the last page's
    /// granule trims the padding of the last packet).
    public static func ogg(_ packets: [Data], inputRate: Int, length: Int, serial: UInt32 = 0x434D_4658) -> Data {
        var head = Data("OpusHead".utf8) + [1, 1]
        head += le(UInt16(preSkip)) + le(UInt32(inputRate)) + le(UInt16(0)) + [0]
        let vendor = Data("CMFX".utf8)
        let tags = Data("OpusTags".utf8) + le(UInt32(vendor.count)) + vendor + le(UInt32(0))
        var out = Data()
        var seq: UInt32 = 0
        func page(_ ps: [Data], flags: UInt8, granule: Int64) {
            var table: [UInt8] = []
            for p in ps {
                table += [UInt8](repeating: 255, count: p.count / 255) + [UInt8(p.count % 255)]
            }
            var pg = Data("OggS".utf8) + [0, flags] + le(UInt64(bitPattern: granule)) + le(serial) + le(seq) + le(UInt32(0))
            pg += [UInt8(table.count)] + table
            for p in ps { pg += p }
            let crc = crc32(pg)
            pg.replaceSubrange(22..<26, with: le(crc))
            out += pg
            seq += 1
        }
        page([head], flags: 2, granule: 0)
        page([tags], flags: 0, granule: 0)
        var granule = Int64(preSkip)
        var i = 0
        while i < packets.count {
            // at most 255 lacing values a page
            var batch: [Data] = []
            var lacing = 0
            while i < packets.count, lacing + packets[i].count / 255 + 1 <= 255, batch.count < 50 {
                lacing += packets[i].count / 255 + 1
                batch.append(packets[i])
                i += 1
            }
            granule += Int64(batch.count * frames)
            let last = i == packets.count
            page(batch, flags: last ? 4 : 0, granule: last ? Int64(preSkip + length) : granule)
        }
        return out
    }

    /// An Ogg Opus (or any audio file iOS reads) → mono samples at `rate`, -1...1.
    public static func decode(_ data: Data, rate: Double) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).ogg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let want = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: file.processingFormat, to: want) else { throw Failure.decode }
        var out: [Float] = []
        var done = false
        while true {
            guard let dst = AVAudioPCMBuffer(pcmFormat: want, frameCapacity: 8192) else { throw Failure.decode }
            var err: NSError?
            let status = conv.convert(to: dst, error: &err) { n, st in
                if done { st.pointee = .endOfStream; return nil }
                guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n),
                      (try? file.read(into: b, frameCount: n)) != nil, b.frameLength > 0 else {
                    done = true
                    st.pointee = .endOfStream
                    return nil
                }
                st.pointee = .haveData
                return b
            }
            if status == .error { throw err ?? Failure.decode }
            out += UnsafeBufferPointer(start: dst.floatChannelData![0], count: Int(dst.frameLength))
            if status == .endOfStream || dst.frameLength == 0 { break }
        }
        return out
    }

    static func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, from 0.
    static func crc32(_ d: Data) -> UInt32 {
        var crc: UInt32 = 0
        for b in d {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? crc << 1 ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}
