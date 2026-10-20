import AVFoundation
import Foundation

/// Asks the Hub to call one of the user's bots. The device captures and plays the audio, which
/// goes up and down the call's channel as `LinkCallAudio`; the Hub connects it to the bot's voice.
public struct LinkCallStart: Codable, Equatable, Sendable {
    public var conversationID: UUID
    /// The call the bot placed that this answers, as `callRinging` named it. Nil when the person calls.
    public var answering: UUID?

    public init(conversationID: UUID, answering: UUID? = nil) {
        self.conversationID = conversationID
        self.answering = answering
    }
}

/// A call one of the user's bots placed, ringing on their devices. Nothing connects to the bot's voice
/// until a device answers it with `startCall`.
public struct LinkIncomingCall: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var botID: UUID
    /// The bot's conversation with the user, where the call is answered or left as missed.
    public var conversationID: UUID
    /// Why the bot is calling.
    public var reason: String
    /// How long it rings on from when the Hub sent it before it counts as missed. Seconds left rather than a
    /// time, so a device whose clock is off rings as long as the Hub.
    public var secondsLeft: TimeInterval

    public init(id: UUID, botID: UUID, conversationID: UUID, reason: String, secondsLeft: TimeInterval) {
        self.id = id; self.botID = botID; self.conversationID = conversationID; self.reason = reason; self.secondsLeft = secondsLeft
    }

    private enum CodingKeys: String, CodingKey { case id, botID, conversationID, reason, secondsLeft, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        botID = try c.decode(UUID.self, forKey: .botID)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        reason = try c.decode(.reason, or: "")
        // Hubs that sent a time instead are read as well as this device's clock allows.
        if let seconds = try c.decodeIfPresent(TimeInterval.self, forKey: .secondsLeft) { secondsLeft = seconds }
        else if let expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt) { secondsLeft = expiresAt.timeIntervalSinceNow }
        else { secondsLeft = 45 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(botID, forKey: .botID)
        try c.encode(conversationID, forKey: .conversationID)
        try c.encode(reason, forKey: .reason)
        try c.encode(secondsLeft, forKey: .secondsLeft)
    }
}

/// How a call a bot placed ended without being answered.
public enum LinkUnansweredCall: String, Codable, Equatable, Sendable { case missed, declined }

public struct LinkCallLine: Codable, Equatable, Sendable {
    public enum Speaker: String, Codable, Sendable { case you, bot }

    public var speaker: Speaker
    public var text: String
    /// When it was said, so it can be shown among what was typed during the call.
    public var at: Date?

    public init(speaker: Speaker, text: String, at: Date?) {
        self.speaker = speaker
        self.text = text
        self.at = at
    }
}

/// A call as its conversation shows it, on the message that marks where it started.
public struct LinkCallRecord: Codable, Equatable, Sendable {
    public var botID: UUID
    /// Nil while the call is on.
    public var endedAt: Date?
    public var lines: [LinkCallLine]
    /// Set for a call the bot placed that nobody answered. Nil from older Hubs, whose cards are all calls that happened.
    public var unanswered: LinkUnansweredCall?
    /// Why the bot called, for a call it placed.
    public var reason: String?

    public init(botID: UUID, endedAt: Date? = nil, lines: [LinkCallLine] = [], unanswered: LinkUnansweredCall? = nil, reason: String? = nil) {
        self.botID = botID
        self.endedAt = endedAt
        self.lines = lines
        self.unanswered = unanswered
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case botID, endedAt, lines, unanswered, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        botID = try c.decode(UUID.self, forKey: .botID)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        lines = try c.decode(.lines, or: [])
        // A kind of unanswered call a later Hub adds reads as missed.
        unanswered = try c.decodeIfPresent(String.self, forKey: .unanswered).map { LinkUnansweredCall(rawValue: $0) ?? .missed }
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// A voice a bot on a harness can speak with on calls.
public struct LinkCallVoice: Codable, Hashable, Identifiable, Sendable {
    public enum Presentation: String, Codable, Sendable { case feminine, masculine }

    public var id: String
    public var name: String
    public var presentation: Presentation

    public init(id: String, name: String, presentation: Presentation) {
        self.id = id
        self.name = name
        self.presentation = presentation
    }
}

/// What comes down a call's channel, one JSON frame each, among the audio. Closing the channel hangs up.
public enum LinkCallEvent: Codable, Equatable, Sendable {
    case started
    case line(LinkCallLine)
    /// The detail is nil when the call ended without an error.
    case ended(String?)

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init?(_ frame: Data) {
        guard let event = try? JSONDecoder().decode(Self.self, from: frame) else { return nil }
        self = event
    }
}

/// A call's audio, both ways on its channel: the person's voice up, the bot's down. Each frame is
/// one Opus packet of 20 ms at 48 kHz mono, behind a zero byte, which no JSON event starts with.
public enum LinkCallAudio {
    public static let sampleRate = 48_000
    public static let frameSamples = 960

    public static func frame(_ packet: Data) -> Data { Data([0]) + packet }

    public static func packet(in frame: Data) -> Data? {
        guard frame.first == 0 else { return nil }
        return frame.dropFirst()
    }

    static let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!

    static let opus: AVAudioFormat = {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameSamples), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)!
    }()
}

/// Turns audio, in pieces of any length, into the call's packets. Use it from one thread at a time.
public final class LinkCallEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private var pending: [Int16] = []

    public init() throws {
        guard let converter = AVAudioConverter(from: LinkCallAudio.pcm, to: LinkCallAudio.opus) else {
            throw LinkError("This device cannot encode call audio.")
        }
        converter.bitRate = 32_000
        self.converter = converter
    }

    public func encode(_ samples: [Int16]) throws -> [Data] {
        pending += samples
        var packets: [Data] = []
        let size = LinkCallAudio.frameSamples
        while pending.count >= size {
            let input = AVAudioPCMBuffer(pcmFormat: LinkCallAudio.pcm, frameCapacity: AVAudioFrameCount(size))!
            input.frameLength = AVAudioFrameCount(size)
            pending.withUnsafeBufferPointer { input.int16ChannelData![0].update(from: $0.baseAddress!, count: size) }
            pending.removeFirst(size)
            let packet = AVAudioCompressedBuffer(format: LinkCallAudio.opus, packetCapacity: 1,
                                                 maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
            var given = false
            var error: NSError?
            let status = converter.convert(to: packet, error: &error) { _, state in
                if given { state.pointee = .noDataNow; return nil }
                given = true
                state.pointee = .haveData
                return input
            }
            if status == .error { throw error ?? LinkError("Call audio could not be encoded.") }
            if packet.byteLength > 0 { packets.append(Data(bytes: packet.data, count: Int(packet.byteLength))) }
        }
        return packets
    }
}

/// Turns the call's packets back into audio. Use it from one thread at a time.
public final class LinkCallDecoder: @unchecked Sendable {
    private let converter: AVAudioConverter

    public init() throws {
        guard let converter = AVAudioConverter(from: LinkCallAudio.opus, to: LinkCallAudio.pcm) else {
            throw LinkError("This device cannot decode call audio.")
        }
        self.converter = converter
    }

    public func decode(_ packet: Data) throws -> [Int16] {
        guard !packet.isEmpty else { return [] }
        let compressed = AVAudioCompressedBuffer(format: LinkCallAudio.opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        let output = AVAudioPCMBuffer(pcmFormat: LinkCallAudio.pcm, frameCapacity: AVAudioFrameCount(LinkCallAudio.frameSamples))!
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return compressed
        }
        if status == .error { throw error ?? LinkError("Call audio could not be decoded.") }
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
    }
}

/// The bot's voice waiting to be played. Packets arrive unevenly, so playing starts only once a
/// cushion has built up, and again after running dry; far behind, the oldest audio goes.
public final class LinkCallPlayout: @unchecked Sendable {
    private let cushion: Int
    private let limit: Int
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var playing = false

    /// By default 60 ms of cushion and at most half a second behind.
    public init(cushion: Int = LinkCallAudio.sampleRate * 6 / 100, limit: Int = LinkCallAudio.sampleRate / 2) {
        self.cushion = cushion
        self.limit = limit
    }

    public func append(_ more: [Int16]) {
        lock.withLock {
            samples += more
            if samples.count > limit { samples.removeFirst(samples.count - limit) }
        }
    }

    /// Fills `out`, with silence for whatever is not there yet.
    public func read(into out: inout [Int16]) {
        out.withUnsafeMutableBufferPointer { read(into: $0) }
    }

    public func read(into out: UnsafeMutableBufferPointer<Int16>) {
        lock.withLock {
            if !playing, samples.count >= cushion { playing = true }
            let count = playing ? min(samples.count, out.count) : 0
            for index in 0..<count { out[index] = samples[index] }
            for index in count..<out.count { out[index] = 0 }
            samples.removeFirst(count)
            if playing, samples.isEmpty, count < out.count { playing = false }
        }
    }
}
