import AVFoundation
import CallKit
import HubLink
import SwiftUI
import UIKit

/// A call's channel to the Hub, which runs the bot, holds the call's connection to its voice,
/// keeps the call's card and hears what is typed meanwhile.
protocol CallChannel: AnyObject, Sendable {
    var frames: AsyncThrowingStream<Data, Error> { get }
    func send(_ payload: Data)
    func cancel()
}

extension LinkChannel: CallChannel {}

/// The microphone and the bot's voice for one call. The audio goes to and from the Hub over the
/// call's channel.
@MainActor protocol CallAudio: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    /// Where the bot's voice waits to be played.
    var playout: LinkCallPlayout { get }
    /// Asks for the microphone and starts listening and playing; what the person says goes to
    /// `hear`, 48 kHz mono, from the audio thread. `sessionActive` says iOS already activated the
    /// audio session for a call on the phone's call screen.
    func start(sessionActive: Bool, hear: @escaping @Sendable ([Int16]) -> Void) async throws
    func setMuted(_ muted: Bool)
    func setSpeaker(_ on: Bool)
    func announceConnected()
    func close()
}

/// The phone's own call screen, which keeps a call going and shows it while the phone is locked.
@MainActor protocol SystemCalls: AnyObject {
    /// Ended or muted from the call screen.
    var onEnd: ((UUID) -> Void)? { get set }
    var onMute: ((UUID, Bool) -> Void)? { get set }
    /// Puts the call on the call screen and returns once iOS has given it its audio. False when
    /// this phone has no call screen for apps, as in China.
    func begin(_ id: UUID, name: String) async throws -> Bool
    func connected(_ id: UUID)
    func setMuted(_ id: UUID, _ muted: Bool)
    func end(_ id: UUID)
}

/// One call at a time on this Hub: starting another hangs up the current one.
@MainActor @Observable final class PhoneCalls {
    struct Call: Equatable {
        let id = UUID()
        let threadID: UUID
        let conversationID: UUID
        /// Nil while connecting.
        var startedAt: Date?
        var isMuted = false
        var isSpeaker = false
        var lines: [LinkCallLine] = []
    }

    private(set) var call: Call?
    /// Why the last call ended, when it went wrong.
    var problem: String?
    @ObservationIgnored private let open: @MainActor (LinkCallStart) async throws -> any CallChannel
    @ObservationIgnored private let makeAudio: @MainActor () -> any CallAudio
    @ObservationIgnored private let system: (any SystemCalls)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var channel: (any CallChannel)?
    @ObservationIgnored private var audio: (any CallAudio)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(open: @escaping @MainActor (LinkCallStart) async throws -> any CallChannel,
         makeAudio: @escaping @MainActor () -> any CallAudio = { EngineCallAudio() },
         system: (any SystemCalls)? = PhoneCallScreen(), now: @escaping () -> Date = Date.init) {
        self.open = open
        self.makeAudio = makeAudio
        self.system = system
        self.now = now
        system?.onEnd = { [weak self] id in
            guard let self, self.call?.id == id else { return }
            self.end(id, problem: nil)
        }
        system?.onMute = { [weak self] id, muted in
            guard let self, self.call?.id == id, self.call?.isMuted != muted else { return }
            self.call?.isMuted = muted
            self.audio?.setMuted(muted)
        }
    }

    func start(threadID: UUID, conversationID: UUID, name: String) {
        hangUp()
        problem = nil
        let call = Call(threadID: threadID, conversationID: conversationID)
        let audio = makeAudio()
        self.call = call
        self.audio = audio
        audio.onFailure = { [weak self] in self?.end(call.id, problem: $0) }
        let speaking = SpokenAudio()
        task = Task { [weak self, system] in
            do {
                let sessionActive = try await system?.begin(call.id, name: name) ?? false
                guard self?.call?.id == call.id else { return }
                try await audio.start(sessionActive: sessionActive, hear: speaking.hear)
                guard let self, self.call?.id == call.id else { return }
                let channel = try await self.open(LinkCallStart(conversationID: conversationID))
                guard self.call?.id == call.id else { return channel.cancel() }
                self.channel = channel
                let encoder = try LinkCallEncoder(), decoder = try LinkCallDecoder()
                speaking.connect { samples in
                    for packet in (try? encoder.encode(samples)) ?? [] { channel.send(LinkCallAudio.frame(packet)) }
                }
                let playout = audio.playout
                // The bot's voice is decoded as it arrives, off the main actor; only events come back here.
                let events = Task.detached {
                    for try await frame in channel.frames {
                        if let packet = LinkCallAudio.packet(in: frame) {
                            if let samples = try? decoder.decode(packet) { playout.append(samples) }
                        } else if let event = LinkCallEvent(frame) {
                            await self.handle(event, of: call.id)
                            if case .ended = event { break }
                        }
                    }
                }
                _ = try await withTaskCancellationHandler { try await events.value } onCancel: { events.cancel() }
                self.end(call.id, problem: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.end(call.id, problem: error is CancellationError ? nil : error.localizedDescription)
            }
        }
    }

    func hangUp() {
        guard let call else { return }
        end(call.id, problem: nil)
    }

    func toggleSpeaker() {
        guard call != nil else { return }
        call?.isSpeaker.toggle()
        audio?.setSpeaker(call?.isSpeaker ?? false)
    }

    func toggleMute() {
        guard let current = call else { return }
        call?.isMuted.toggle()
        let muted = call?.isMuted ?? false
        audio?.setMuted(muted)
        system?.setMuted(current.id, muted)
    }

    private func handle(_ event: LinkCallEvent, of id: UUID) {
        guard call?.id == id else { return }
        switch event {
        case .started:
            guard call?.startedAt == nil else { return }
            call?.startedAt = now()
            audio?.announceConnected()
            system?.connected(id)
        case .line(let line):
            call?.lines.append(line)
        case .ended(let detail):
            end(id, problem: detail)
        }
    }

    private func end(_ id: UUID, problem: String?) {
        guard call?.id == id else { return }
        task?.cancel()
        task = nil
        channel?.cancel()
        channel = nil
        audio?.onFailure = nil
        audio?.close()
        audio = nil
        call = nil
        system?.end(id)
        if let problem { self.problem = problem }
    }
}

/// Where what the person says goes: nowhere until the call is connected.
final class SpokenAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var send: (@Sendable ([Int16]) -> Void)?

    func connect(_ send: @escaping @Sendable ([Int16]) -> Void) { lock.withLock { self.send = send } }
    func hear(_ samples: [Int16]) { lock.withLock { send }?(samples) }
}

/// Calls on the phone's own call screen through CallKit, so they keep going, and show, while the
/// phone is locked, and its buttons and headsets' mute and end them.
@MainActor final class PhoneCallScreen: NSObject, SystemCalls, @preconcurrency CXProviderDelegate {
    var onEnd: ((UUID) -> Void)?
    var onMute: ((UUID, Bool) -> Void)?
    private let provider: CXProvider?
    private let controller = CXCallController()
    private var activation: (id: UUID, continuation: CheckedContinuation<Bool, Error>)?
    /// Calls this app ended itself, whose end action should not report back.
    private var ending: Set<UUID> = []

    override init() {
        // Apps may not use CallKit in China.
        if Locale.current.region == .chinaMainland {
            provider = nil
        } else {
            let configuration = CXProviderConfiguration()
            configuration.supportsVideo = false
            configuration.maximumCallGroups = 1
            configuration.maximumCallsPerCallGroup = 1
            configuration.supportedHandleTypes = [.generic]
            configuration.includesCallsInRecents = false
            configuration.iconTemplateImageData = UIImage(systemName: "bubble.left.fill")?.pngData()
            provider = CXProvider(configuration: configuration)
        }
        super.init()
        provider?.setDelegate(self, queue: .main)
    }

    func begin(_ id: UUID, name: String) async throws -> Bool {
        guard provider != nil else { return false }
        let start = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: name))
        start.contactIdentifier = name
        // Should iOS not hand the call its audio, the app activates it itself rather than wait on.
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(5))
            self?.finishActivation(id, with: .success(false))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            activation?.continuation.resume(throwing: CancellationError())
            activation = (id, continuation)
            // CallKit answers on a queue of its own.
            controller.request(CXTransaction(action: start)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.finishActivation(id, with: .failure(error)) }
            }
        }
    }

    func connected(_ id: UUID) { provider?.reportOutgoingCall(with: id, connectedAt: nil) }

    func setMuted(_ id: UUID, _ muted: Bool) {
        guard provider != nil else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) { _ in }
    }

    func end(_ id: UUID) {
        guard provider != nil else { return }
        finishActivation(id, with: .failure(CancellationError()))
        ending.insert(id)
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { [weak self] error in
            // A call iOS no longer knows needs no ending.
            guard error != nil else { return }
            Task { @MainActor in _ = self?.ending.remove(id) }
        }
    }

    private func finishActivation(_ id: UUID, with result: Result<Bool, Error>) {
        guard let activation, activation.id == id else { return }
        self.activation = nil
        activation.continuation.resume(with: result)
    }

    func providerDidReset(_ provider: CXProvider) {
        if let id = activation?.id { finishActivation(id, with: .failure(CancellationError())) }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Set up, not activated: iOS activates the session for the call.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            action.fulfill()
        } catch {
            action.fail()
            finishActivation(action.callUUID, with: .failure(error))
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        if let id = activation?.id { finishActivation(id, with: .success(true)) }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        if ending.remove(action.callUUID) == nil { onEnd?(action.callUUID) }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
        onMute?(action.callUUID, action.isMuted)
    }
}

/// The microphone and the bot's voice through the phone's audio engine. The earpiece, or
/// headphones and AirPods when connected, play the voice as it is; the loudspeaker needs echo
/// cancellation, which comes with call voice processing and narrows the voice to a phone line.
@MainActor final class EngineCallAudio: CallAudio {
    var onFailure: ((String) -> Void)?
    let playout = LinkCallPlayout()
    private let microphone = MicrophoneTap()
    private var engine: AVAudioEngine?
    private var speaker = false
    private var requestedSpeaker = false
    private var routeTask: Task<Void, Never>?
    private var interruption: NSObjectProtocol?
    private var configuration: NSObjectProtocol?
    private var closed = false

    func start(sessionActive: Bool, hear: @escaping @Sendable ([Int16]) -> Void) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw LinkError("Microphone access is off. Allow Noodle in Settings → Privacy & Security → Microphone.")
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        microphone.hear = hear
        try Self.setUp(speaker: false, activate: !sessionActive)
        try startEngine(speaker: false)
        // A phone call or Siri interrupts the call; it cannot pick up again by itself.
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in if began { self?.onFailure?("The call was interrupted.") } }
        }
        configuration = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            let changed = ObjectIdentifier(note.object as AnyObject)
            Task { @MainActor in
                guard let self, let engine = self.engine, ObjectIdentifier(engine) == changed, self.routeTask == nil else { return }
                do { try self.resume(engine) } catch { self.onFailure?("The call's audio stopped.") }
            }
        }
        if requestedSpeaker { setSpeaker(true) }
    }

    /// Changing the session under a running microphone silences it, so the session changes only
    /// with the engine stopped.
    private static func setUp(speaker: Bool, activate: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if speaker {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        } else {
            // A2DP plays AirPods at full quality while the phone's microphone listens.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        }
        if activate { try session.setActive(true) }
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    private func startEngine(speaker: Bool) throws {
        engine?.stop()
        let engine = AVAudioEngine()
        try engine.inputNode.setVoiceProcessingEnabled(speaker)
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(LinkCallAudio.sampleRate), channels: 1)!
        let voice = Self.voice(from: playout, format: format)
        engine.attach(voice)
        engine.connect(voice, to: engine.mainMixerNode, format: format)
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else { throw LinkError("The microphone could not start.") }
        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: input, block: Self.tap(microphone))
        engine.prepare()
        try engine.start()
        // Starting voice processing sends the voice back to the earpiece.
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
        self.engine = engine
        self.speaker = speaker
    }

    /// The audio thread calls these, so they must not belong to the main actor as closures made
    /// inside its methods would.
    nonisolated private static func voice(from playout: LinkCallPlayout, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            let out = UnsafeMutableAudioBufferListPointer(buffers)[0]
            let samples = out.mData!.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)
            let read = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
            defer { read.deallocate() }
            playout.read(into: read)
            for index in 0..<count { samples[index] = Float(read[index]) / 32_768 }
            return noErr
        }
    }

    nonisolated private static func tap(_ microphone: MicrophoneTap) -> AVAudioNodeTapBlock {
        { buffer, _ in microphone.deliver(buffer) }
    }

    /// After a configuration change, the same engine listens again in the new format. A new
    /// engine would set voice processing up again, which reports another change.
    private func resume(_ engine: AVAudioEngine) throws {
        guard !engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else { throw LinkError("The microphone could not start.") }
        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: input, block: Self.tap(microphone))
        engine.prepare()
        try engine.start()
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    func setMuted(_ muted: Bool) { microphone.isMuted = muted }

    func setSpeaker(_ on: Bool) {
        requestedSpeaker = on
        guard engine != nil, !closed, routeTask == nil, requestedSpeaker != speaker else { return }
        // One route change at a time; further taps replace the requested route.
        routeTask = Task { [weak self] in
            guard let self else { return }
            defer { routeTask = nil }
            while !closed, requestedSpeaker != speaker {
                let on = requestedSpeaker
                engine?.inputNode.removeTap(onBus: 0)
                engine?.stop()
                do {
                    try Self.setUp(speaker: on, activate: false)
                    try startEngine(speaker: on)
                } catch {
                    if !closed { onFailure?(error.localizedDescription) }
                    return
                }
                await Task.yield()
            }
        }
    }

    func announceConnected() { playout.append(Self.chime) }

    func close() {
        closed = true
        routeTask?.cancel()
        routeTask = nil
        microphone.hear = nil
        [interruption, configuration].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        interruption = nil
        configuration = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Two rising notes, played to the person only.
    private static let chime: [Int16] = {
        let rate = Double(LinkCallAudio.sampleRate)
        return (0..<Int(rate * 0.43)).map { index in
            let time = Double(index) / rate
            let sum = [(660.0, 0.0), (880.0, 0.13)].reduce(0.0) { sum, note in
                let local = time - note.1
                guard local >= 0, local < 0.3 else { return sum }
                let level = local < 0.02 ? local / 0.02 * 0.18 : 0.18 * pow(0.001 / 0.18, (local - 0.02) / 0.26)
                return sum + sin(2 * .pi * note.0 * local) * min(level, 0.18)
            }
            return Int16(max(-1, min(1, sum)) * 32_767)
        }
    }()
}

/// Turns the microphone's buffers, in whatever format the phone gives, into the call's audio.
final class MicrophoneTap: @unchecked Sendable {
    private let lock = NSLock()
    private var _hear: (@Sendable ([Int16]) -> Void)?
    private var _muted = false
    private var converter: AVAudioConverter?
    private static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(LinkCallAudio.sampleRate),
                                              channels: 1, interleaved: true)!

    var hear: (@Sendable ([Int16]) -> Void)? {
        get { lock.withLock { _hear } }
        set { lock.withLock { _hear = newValue } }
    }

    var isMuted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    /// Called on the audio thread. Only the first channel is the voice.
    func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let hear, !isMuted, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let rate = buffer.format.sampleRate
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
        input.frameLength = buffer.frameLength
        input.floatChannelData![0].update(from: channel, count: Int(buffer.frameLength))
        if converter?.inputFormat.sampleRate != rate { converter = AVAudioConverter(from: mono, to: Self.target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Double(LinkCallAudio.sampleRate) / rate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
        var given = false
        _ = converter.convert(to: output, error: nil) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return input
        }
        guard output.frameLength > 0 else { return }
        hear(Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength))))
    }
}

/// One stretch of a call between two messages.
struct CallBlock: Equatable {
    let botID: UUID
    var lines: [LinkCallLine]
    let isLive: Bool
}

enum CallLayout {
    /// Each spoken line goes after the last message sent before it was said, but never above its
    /// own call, so messages sent during a call split its transcript into blocks.
    static func blocks(in messages: [LinkMessage], live: (messageID: UUID, lines: [LinkCallLine])?) -> [UUID: CallBlock] {
        var placed: [UUID: CallBlock] = [:]
        for (index, card) in messages.enumerated() {
            guard let record = card.call else { continue }
            let isLive = live?.messageID == card.id
            for line in isLive ? live?.lines ?? [] : record.lines {
                var host = index
                if let at = line.at {
                    while host + 1 < messages.count, messages[host + 1].createdAt <= at { host += 1 }
                }
                placed[messages[host].id, default: CallBlock(botID: record.botID, lines: [], isLive: isLive)].lines.append(line)
            }
        }
        return placed
    }

    /// Elapsed time in a slot as wide as "00:00", so the bar never moves.
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }
}

/// While this conversation is on a call: its time, Mute and End, over the conversation, which stays usable.
struct CallBar: View {
    let calls: PhoneCalls
    let call: PhoneCalls.Call

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "phone.fill")
                .foregroundStyle(call.startedAt == nil ? Color.secondary : Color.green)
            ZStack(alignment: .leading) {
                Text("00:00").hidden()
                if let startedAt = call.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(CallLayout.elapsed(context.date.timeIntervalSince(startedAt)))
                    }
                } else {
                    Text("--:--")
                }
            }
            .monospacedDigit()
            .accessibilityLabel(call.startedAt == nil ? "Connecting" : "On a call")
            Spacer()
            Button { calls.toggleSpeaker() } label: {
                Image(systemName: call.isSpeaker ? "speaker.wave.3.fill" : "speaker.fill").frame(width: 28)
            }
            .tint(call.isSpeaker ? .accentColor : .primary)
            .accessibilityLabel("Speaker")
            .accessibilityAddTraits(call.isSpeaker ? .isSelected : [])
            Button { calls.toggleMute() } label: {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill").frame(width: 24)
            }
            .accessibilityLabel(call.isMuted ? "Unmute" : "Mute")
            Button(role: .destructive) { calls.hangUp() } label: {
                Image(systemName: "phone.down.fill").frame(width: 24)
            }
            .tint(.red)
            .accessibilityLabel("End Call")
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

/// Where a call starts in its conversation: live while it runs, then its length.
struct CallCardRow: View {
    let name: String
    let message: LinkMessage
    let record: LinkCallRecord
    let live: PhoneCalls.Call?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: live == nil ? "phone" : "phone.fill")
                .foregroundStyle(live == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Voice call with \(name)").font(.subheadline.weight(.medium))
                Group {
                    if let startedAt = live?.startedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(CallLayout.elapsed(context.date.timeIntervalSince(startedAt))).monospacedDigit()
                        }
                    } else if let endedAt = record.endedAt {
                        Text(Duration.seconds(max(0, endedAt.timeIntervalSince(message.createdAt)))
                            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity)
    }
}

/// A stretch of what was said on a call, kept to a two-line preview. Tapping it shows all of it.
struct CallBlockRow: View {
    let name: String
    let block: CallBlock
    @State private var showsAll = false

    var body: some View {
        // A live block follows the conversation; a finished one reads from its start.
        let preview = block.isLive ? Array(block.lines.suffix(2)) : Array(block.lines.prefix(2))
        Button { showsAll = true } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, line in
                        (Text(speaker(line) + "  ").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            + Text(line.text).font(.subheadline))
                            .lineLimit(1)
                    }
                    if block.lines.count > preview.count {
                        Text("\(block.lines.count) lines").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .accessibilityHint("Shows what was said")
        .sheet(isPresented: $showsAll) {
            NavigationStack {
                List(Array(block.lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker(line)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(line.text).textSelection(.enabled)
                    }
                }
                .navigationTitle("Call")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsAll = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func speaker(_ line: LinkCallLine) -> String { line.speaker == .you ? "You" : name }
}

/// A short sample of each harness voice, shipped with the app, so choosing needs no call.
enum VoiceSample {
    static func url(provider: String, voice: String) -> URL? {
        Bundle.main.url(forResource: "\(provider)-\(voice)", withExtension: "m4a", subdirectory: "VoicePreviews")
    }
}

/// A bot's voice: tapping one chooses it and plays its sample, so voices can be compared.
struct VoicePicker: View {
    let provider: String
    let voices: [LinkCallVoice]
    @Binding var selection: String?
    @State private var player: AVAudioPlayer?
    @State private var playing: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Feminine", .feminine)
                group("Masculine", .masculine)
            }
            .padding()
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player?.stop() }
    }

    private func group(_ title: String, _ presentation: LinkCallVoice.Presentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(voices.filter { $0.presentation == presentation }) { voice in tile(voice) }
            }
        }
    }

    private func tile(_ voice: LinkCallVoice) -> some View {
        let isSelected = selection == voice.id
        return Button {
            selection = voice.id
            play(voice.id)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .symbolEffect(.variableColor.iterative, isActive: playing == voice.id)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(voice.name).font(.subheadline.weight(isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.name)
        .accessibilityHint("Chooses this voice and plays a sample")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func play(_ voice: String) {
        player?.stop()
        playing = nil
        guard let url = VoiceSample.url(provider: provider, voice: voice), let next = try? AVAudioPlayer(contentsOf: url) else { return }
        // Heard with the ring switch on silent, as a voice someone asked to hear should be; a call
        // in progress keeps its own audio set-up.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback)
            try? session.setActive(true)
        }
        next.play()
        player = next
        playing = voice
        Task {
            try? await Task.sleep(for: .seconds(next.duration))
            if player === next { playing = nil }
        }
    }
}
