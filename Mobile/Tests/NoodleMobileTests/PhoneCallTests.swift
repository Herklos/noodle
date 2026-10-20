import Foundation
import HubLink
@testable import NoodleMobile
import Testing

final class CallChannelFake: CallChannel, @unchecked Sendable {
    let frames: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var _sent: [Data] = []
    private var _cancelled = 0
    var sent: [Data] { lock.withLock { _sent } }
    var cancelled: Int { lock.withLock { _cancelled } }
    init() { (frames, continuation) = AsyncThrowingStream.makeStream() }
    func push(_ event: LinkCallEvent) { continuation.yield(event.encoded) }
    func push(audio frame: Data) { continuation.yield(frame) }
    func send(_ payload: Data) { lock.withLock { _sent.append(payload) } }
    func cancel() { lock.withLock { _cancelled += 1 }; continuation.finish(throwing: CancellationError()) }
}

@MainActor final class CallAudioFake: CallAudio {
    var onFailure: ((String) -> Void)?
    let playout = LinkCallPlayout(cushion: 1)
    var startError: Error?
    var hear: (@Sendable ([Int16]) -> Void)?
    var sessionActive: [Bool] = []
    var muted: [Bool] = []
    var speaker: [Bool] = []
    var chimes = 0
    var closed = 0
    func start(sessionActive: Bool, hear: @escaping @Sendable ([Int16]) -> Void) async throws {
        if let startError { throw startError }
        self.sessionActive.append(sessionActive)
        self.hear = hear
    }
    func setMuted(_ muted: Bool) { self.muted.append(muted) }
    func setSpeaker(_ on: Bool) { speaker.append(on) }
    func announceConnected() { chimes += 1 }
    func close() { closed += 1 }
}

@MainActor final class SystemCallsFake: SystemCalls {
    var onEnd: ((UUID) -> Void)?
    var onMute: ((UUID, Bool) -> Void)?
    var onAnswer: ((UUID) -> Bool)?
    /// Runs while iOS puts a call on the call screen.
    var onRing: (() -> Void)?
    var beginError: Error?
    var rung: [(UUID, String)] = []
    var answeredCalls: [UUID] = []
    var stopped: [(UUID, Bool)] = []
    var begun: [(UUID, String)] = []
    var connected: [UUID] = []
    var muted: [Bool] = []
    var ended: [UUID] = []
    func begin(_ id: UUID, name: String) async throws -> Bool {
        if let beginError { throw beginError }
        begun.append((id, name))
        return true
    }
    func ring(_ id: UUID, name: String) async -> Bool {
        rung.append((id, name))
        onRing?()
        return true
    }
    func answered(_ id: UUID) async -> Bool {
        answeredCalls.append(id)
        return true
    }
    func stopRinging(_ id: UUID, unanswered: Bool) { stopped.append((id, unanswered)) }
    func connected(_ id: UUID) { connected.append(id) }
    func setMuted(_ id: UUID, _ muted: Bool) { self.muted.append(muted) }
    func end(_ id: UUID) { ended.append(id) }
}

private struct Failure: LocalizedError {
    let errorDescription: String?
}

@MainActor @Suite struct PhoneCallTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    private var tone: [Int16] { (0..<960).map { Int16(sin(Double($0) * 2 * .pi * 440 / 48_000) * 8000) } }

    /// The phone's audio goes up the call's channel and the bot's comes down it; the Hub holds the
    /// connection to the bot's voice. The call is on the phone's call screen throughout.
    @Test func aCallConnectsThroughTheHubAndEndsWhenEitherSideHangsUp() async throws {
        let channel = CallChannelFake(), audio = CallAudioFake(), system = SystemCallsFake()
        var opened: [LinkCallStart] = []
        let calls = PhoneCalls(open: { opened.append($0); return channel }, makeAudio: { audio }, system: system, now: { [date] in date })
        let thread = UUID(), conversation = UUID()
        calls.start(threadID: thread, conversationID: conversation, name: "Kai")
        #expect(calls.call?.threadID == thread)
        #expect(calls.call?.startedAt == nil)
        await wait { opened.count == 1 }
        #expect(opened == [LinkCallStart(conversationID: conversation)])
        #expect(system.begun.map(\.1) == ["Kai"])
        #expect(audio.sessionActive == [true], "The call screen activates the audio session, not the app")

        channel.push(.started)
        channel.push(.line(LinkCallLine(speaker: .bot, text: "Hello", at: date)))
        await wait { calls.call?.lines.count == 1 }
        #expect(calls.call?.startedAt == date)
        #expect(audio.chimes == 1)
        #expect(system.connected == [calls.call?.id].compactMap { $0 })
        #expect(calls.call?.lines.map(\.text) == ["Hello"])

        let encoder = try LinkCallEncoder()
        for packet in try encoder.encode(tone + tone + tone) { channel.push(audio: LinkCallAudio.frame(packet)) }
        var played = [Int16](repeating: 0, count: 960)
        for _ in 0..<500 {
            audio.playout.read(into: &played)
            if played.contains(where: { abs(Int($0)) > 1000 }) { break }
            await Task.yield()
        }
        #expect(played.contains { abs(Int($0)) > 1000 }, "The bot's voice reaches the speaker")
        audio.hear?(tone + tone)
        #expect(!channel.sent.isEmpty)
        #expect(channel.sent.allSatisfy { LinkCallAudio.packet(in: $0) != nil }, "The phone's voice goes up as audio frames")

        calls.toggleMute()
        #expect(calls.call?.isMuted == true)
        #expect(audio.muted == [true])
        #expect(system.muted == [true])

        // Calls start on the earpiece, which needs no echo cancellation and so sounds clean.
        #expect(calls.call?.isSpeaker == false)
        calls.toggleSpeaker()
        calls.toggleSpeaker()
        #expect(calls.call?.isSpeaker == false)
        #expect(audio.speaker == [true, false])

        let id = try #require(calls.call?.id)
        calls.hangUp()
        #expect(calls.call == nil)
        #expect(channel.cancelled == 1)
        #expect(audio.closed == 1)
        #expect(system.ended == [id])
        #expect(calls.problem == nil)

        let ending = CallChannelFake(), endingAudio = CallAudioFake()
        let other = PhoneCalls(open: { _ in ending }, makeAudio: { endingAudio }, system: nil, now: { [date] in date })
        other.start(threadID: thread, conversationID: conversation, name: "Kai")
        await wait { endingAudio.hear != nil }
        #expect(endingAudio.sessionActive == [false], "Without the call screen the app activates its own session")
        ending.push(.ended("This bot cannot take calls."))
        await wait { other.call == nil }
        #expect(other.call == nil)
        #expect(other.problem == "This bot cannot take calls.")
        #expect(endingAudio.closed == 1)
    }

    /// A bot's call rings on the call screen. Answering there calls the bot through the Hub as the answer to
    /// that call; declining there tells the Hub; a call the Hub stops stops ringing.
    @Test func aBotsCallRingsOnTheCallScreenUntilItIsAnsweredDeclinedOrStopped() async throws {
        let channel = CallChannelFake(), audio = CallAudioFake(), system = SystemCallsFake()
        var opened: [LinkCallStart] = [], declined: [UUID] = []
        let calls = PhoneCalls(open: { opened.append($0); return channel }, decline: { declined.append($0) },
                               makeAudio: { audio }, system: system, now: { [date] in date })
        let kai = UUID(), conversation = UUID()
        func incoming(expiring seconds: TimeInterval = 45) -> LinkIncomingCall {
            LinkIncomingCall(id: UUID(), botID: kai, conversationID: conversation, reason: "The build is broken", secondsLeft: seconds)
        }

        let answered = incoming()
        calls.ring(answered, name: "Kai")
        calls.ring(answered, name: "Kai")
        await wait { !system.rung.isEmpty }
        #expect(system.rung.map { $0.0 } == [answered.id])
        #expect(system.rung.map { $0.1 } == ["Kai"])
        #expect(calls.ringing.map(\.call) == [answered])
        #expect(opened.isEmpty, "Nothing connects to the bot before the call is answered")

        #expect(system.onAnswer?(answered.id) == true)
        await wait { !opened.isEmpty }
        #expect(opened == [LinkCallStart(conversationID: conversation, answering: answered.id)])
        #expect(calls.call?.id == answered.id)
        #expect(system.answeredCalls == [answered.id])
        #expect(system.begun.isEmpty, "An answered call is on the call screen already")
        #expect(calls.ringing.isEmpty)
        #expect(system.onAnswer?(answered.id) == false, "A call no longer ringing cannot be answered again")
        channel.push(.started)
        await wait { calls.call?.startedAt != nil }
        #expect(system.connected.isEmpty, "iOS connected the answered call itself")
        calls.hangUp()

        let refused = incoming()
        calls.ring(refused, name: "Kai")
        await wait { system.rung.count == 2 }
        system.onEnd?(refused.id)
        await wait { !declined.isEmpty }
        #expect(declined == [refused.id])
        #expect(calls.ringing.isEmpty)
        #expect(system.stopped.isEmpty, "Declining on the call screen stopped it there already")

        let elsewhere = incoming()
        calls.ring(elsewhere, name: "Kai")
        await wait { system.rung.count == 3 }
        calls.stopRinging(elsewhere.id)
        #expect(system.stopped.map { $0.0 } == [elsewhere.id])
        #expect(system.stopped.map { $0.1 } == [false])
        #expect(calls.ringing.isEmpty)

        calls.ring(incoming(expiring: 0), name: "Kai")
        #expect(calls.ringing.isEmpty, "A call that already expired never rings")

        // Stopped while iOS put it on the call screen: once there, it is ended there.
        let late = incoming()
        system.onRing = { calls.stopRinging(late.id) }
        calls.ring(late, name: "Kai")
        await wait { system.stopped.filter { $0.0 == late.id }.count == 2 }
        #expect(system.stopped.filter { $0.0 == late.id }.count == 2)
        #expect(calls.ringing.isEmpty)
    }

    @Test func aCallThatCannotUseTheMicrophoneNeverReachesTheHub() async throws {
        let audio = CallAudioFake(), system = SystemCallsFake()
        audio.startError = Failure(errorDescription: "Microphone access is off.")
        var opened = 0
        let calls = PhoneCalls(open: { _ in opened += 1; return CallChannelFake() }, makeAudio: { audio }, system: system,
                               now: { [date] in date })
        calls.start(threadID: UUID(), conversationID: UUID(), name: "Kai")
        await wait { calls.call == nil }
        #expect(calls.call == nil)
        #expect(opened == 0)
        #expect(calls.problem == "Microphone access is off.")
        #expect(audio.closed == 1)
        #expect(system.ended.count == 1, "The call leaves the call screen too")
    }

    /// Ending or muting from the lock screen, a headset or the call screen acts on the call.
    @Test func theCallScreenEndsAndMutesTheCall() async throws {
        let channel = CallChannelFake(), audio = CallAudioFake(), system = SystemCallsFake()
        let calls = PhoneCalls(open: { _ in channel }, makeAudio: { audio }, system: system, now: { [date] in date })
        calls.start(threadID: UUID(), conversationID: UUID(), name: "Kai")
        await wait { audio.hear != nil }
        let id = try #require(calls.call?.id)
        system.onMute?(id, true)
        #expect(calls.call?.isMuted == true)
        #expect(audio.muted == [true])
        system.onMute?(UUID(), false)
        #expect(calls.call?.isMuted == true, "Another call's button does nothing here")
        system.onEnd?(id)
        #expect(calls.call == nil)
        #expect(audio.closed == 1)
        #expect(calls.problem == nil)
    }

    @Test func aCallTheCallScreenRefusesNeverStarts() async throws {
        let audio = CallAudioFake(), system = SystemCallsFake()
        system.beginError = Failure(errorDescription: "Another call is in progress.")
        var opened = 0
        let calls = PhoneCalls(open: { _ in opened += 1; return CallChannelFake() }, makeAudio: { audio }, system: system,
                               now: { [date] in date })
        calls.start(threadID: UUID(), conversationID: UUID(), name: "Kai")
        await wait { calls.call == nil }
        #expect(opened == 0)
        #expect(audio.hear == nil)
        #expect(calls.problem == "Another call is in progress.")
    }

    @Test func everyVoiceAHubOffersHasASampleHere() {
        for voice in ["juniper", "maple", "sol", "vale", "arbor", "breeze", "cove", "ember", "spruce"] {
            #expect(VoiceSample.url(provider: "codex", voice: voice) != nil, "\(voice)")
        }
        #expect(VoiceSample.url(provider: "codex", voice: "nobody") == nil)
    }

    @Test func whatWasSaidSitsAmongWhatWasSentDuringTheCall() {
        let conversation = UUID(), bot = UUID(), start = date
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        func message(_ seconds: Double, call: LinkCallRecord? = nil) -> LinkMessage {
            LinkMessage(id: UUID(), conversationID: conversation, author: .you, body: "", createdAt: at(seconds), delivered: true, call: call)
        }
        let card = message(0, call: LinkCallRecord(botID: bot, endedAt: at(9), lines: [
            LinkCallLine(speaker: .you, text: "Look at this", at: at(1)),
            LinkCallLine(speaker: .bot, text: "Got it", at: at(5)),
        ]))
        let typed = message(3)
        let blocks = CallLayout.blocks(in: [card, typed], live: nil)
        #expect(blocks[card.id]?.lines.map(\.text) == ["Look at this"])
        #expect(blocks[typed.id]?.lines.map(\.text) == ["Got it"])
        #expect(blocks[typed.id]?.botID == bot)

        let live = CallLayout.blocks(in: [card, typed], live: (card.id, [LinkCallLine(speaker: .bot, text: "Live", at: at(4))]))
        #expect(live[typed.id]?.lines.map(\.text) == ["Live"])
        #expect(live[typed.id]?.isLive == true)
    }
}
