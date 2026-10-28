#if NOODLE_DEV_HOOKS
import AppKit
import Darwin
import NoodleCore
import NoodleRuntime

/// `--scenario-benchmark [PHASES]` drives a scenario through fixed phases instead of its timeline and prints, for
/// each, the frames the main thread missed and how busy it was, then quits. PHASES is a comma-separated list
/// of phase names, or "all". A phase named twice with `:SECONDS` runs that long, for sampling it from outside.
@MainActor final class ScenarioBenchmark {
    private let session: ScenarioSession
    private let phases: [(name: String, seconds: Double?)]
    private let window: NSWindow
    private var frames = FrameCounter()
    private var link: CADisplayLink?
    private var frameAction: ((CFTimeInterval) -> Void)?

    static let all = ["idle-list", "messages-list", "status-list", "switch-list", "switch-bots-list", "scroll-list", "resize-list",
                      "open-columns", "idle-columns", "messages-columns", "status-columns", "scroll-columns", "resize-columns"]

    init(session: ScenarioSession, phases: String, window: NSWindow) {
        self.session = session
        self.window = window
        let named = phases.isEmpty || phases == "all" ? Self.all : phases.split(separator: ",").map(String.init)
        self.phases = named.map { entry in
            let parts = entry.split(separator: ":")
            return (String(parts[0]), parts.count > 1 ? Double(parts[1]) : nil)
        }
    }

    func run() async {
        let link = window.contentView!.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        print("BENCH conversations=\(session.store.conversations.count) window=\(Int(window.frame.width))x\(Int(window.frame.height))")
        try? await Task.sleep(for: .seconds(2))
        for phase in phases {
            guard Self.all.contains(phase.name) else { print("BENCH unknown phase \(phase.name)"); continue }
            await prepare(phase.name)
            let started = Measurement.now()
            frames = FrameCounter()
            await perform(phase.name, for: phase.seconds ?? (phase.name.hasPrefix("idle") ? 3 : 6))
            frameAction = nil
            print("BENCH \(phase.name) " + Measurement.now().report(since: started, frames: frames))
            try? await Task.sleep(for: .seconds(1))
        }
        link.invalidate()
        fflush(stdout)
    }

    @objc private func tick(_ link: CADisplayLink) {
        frames.record(link.timestamp, nominal: link.duration)
        frameAction?(link.timestamp)
    }

    private var store: NoodleStore { session.store }
    private var conversations: [BotConversation] { store.conversations.sorted { $0.id.uuidString < $1.id.uuidString } }

    private func prepare(_ phase: String) async {
        let columns = phase.hasSuffix("-columns")
        let layout = columns ? MainWindowLayout.columns : .list
        if UserDefaults.standard.string(forKey: MainWindowLayout.key) != layout.rawValue {
            UserDefaults.standard.set(layout.rawValue, forKey: MainWindowLayout.key)
            try? await Task.sleep(for: .seconds(1))
        }
        if !columns, let first = conversations.first { store.selectedConversationID = first.id }
    }

    private func perform(_ phase: String, for seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        switch phase {
        case "open-columns":
            // Ten conversations opened one after another, the way a person builds a set.
            for conversation in conversations.prefix(10) {
                store.selectedConversationID = conversation.id
                try? await Task.sleep(for: .milliseconds(600))
            }
        case "messages-list", "messages-columns":
            // Replies land four times a second across the open conversations, long and short.
            var index = 0
            let targets = phase == "messages-columns" ? Array(conversations.prefix(10)) : conversations
            while Date() < end {
                let conversation = targets[index % targets.count]
                if let agent = store.participants(for: conversation).first {
                    _ = try? session.repository.sendAgentMessage(agentID: agent.id, conversationID: conversation.id,
                        body: Self.bodies[index % Self.bodies.count], now: session.now)
                    store.refreshTranscripts()
                }
                index += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        case "status-list", "status-columns":
            // Bots switching between working and ready, which every running harness does.
            var index = 0
            let agents = store.agents
            while Date() < end, !agents.isEmpty {
                let agent = agents[index % agents.count]
                let key = session.seeded.agents.first { $0.value.id == agent.id }?.key ?? ""
                let working = index / agents.count % 2 == 0
                session.process(for: key)?.transition(.init(agentID: agent.id, phase: working ? .working : .ready,
                    detail: working ? "Working on step \(index)" : "Ready"))
                index += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        case "switch-list", "switch-bots-list":
            // Every conversation in turn; the bots-only run keeps the toolbar's items the same kinds.
            var index = 0
            let all = phase == "switch-list" ? conversations : conversations.filter {
                $0.kind == .direct && store.pauseSummary(for: $0) == nil && store.companions(in: $0).isEmpty
            }
            while Date() < end {
                store.selectedConversationID = all[index % all.count].id
                index += 1
                try? await Task.sleep(for: .milliseconds(400))
            }
        case "resize-list", "resize-columns":
            // A drag of the window's edge: one size a frame, out and back. Each step must fit in a frame.
            let base = window.frame
            let start = CACurrentMediaTime()
            var steps: [CFTimeInterval] = []
            frameAction = { [window] now in
                let t = now - start
                let delta = (sin(t * .pi) + 1) / 2 * 300
                let before = CACurrentMediaTime()
                window.setFrame(NSRect(x: base.minX, y: base.minY, width: base.width + delta, height: base.height), display: true)
                steps.append(CACurrentMediaTime() - before)
            }
            try? await Task.sleep(for: .seconds(seconds))
            frameAction = nil
            window.setFrame(base, display: true)
            let sorted = steps.sorted()
            if !sorted.isEmpty {
                print(String(format: "BENCH %@ step p50=%.1fms p95=%.1fms", phase, sorted[sorted.count / 2] * 1000, sorted[sorted.count * 95 / 100] * 1000))
            }
        case "scroll-list":
            // A trackpad swipe up the transcript and back down, one position a frame, through a long history.
            if let conversation = store.selectedConversation, let agent = store.participants(for: conversation).first {
                for index in 0..<80 {
                    _ = try? session.repository.sendAgentMessage(agentID: agent.id, conversationID: conversation.id,
                        body: Self.bodies[index % Self.bodies.count], now: session.now)
                }
                store.refreshTranscripts()
                try? await Task.sleep(for: .seconds(1.5))
            }
            frames = FrameCounter()
            guard let scrollView = Self.transcriptScrollView(in: window.contentView) else { print("BENCH no transcript scroll view"); return }
            let start = CACurrentMediaTime()
            let bottom = scrollView.contentView.bounds.minY
            frameAction = { now in
                let range = min(3000, max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height))
                let y = bottom - (1 - cos((now - start) * .pi / 2)) / 2 * range * (scrollView.documentView?.isFlipped == true ? 1 : -1)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            try? await Task.sleep(for: .seconds(seconds))
        case "scroll-columns":
            // A trackpad swipe across the columns and back, one position a frame.
            guard let scrollView = Self.horizontalScrollView(in: window.contentView) else { print("BENCH no columns scroll view"); return }
            let start = CACurrentMediaTime()
            frameAction = { now in
                let range = max(0, (scrollView.documentView?.frame.width ?? 0) - scrollView.contentView.bounds.width)
                let x = (1 - cos((now - start) * .pi / 2)) / 2 * range
                scrollView.contentView.scroll(to: NSPoint(x: x, y: scrollView.contentView.bounds.minY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            try? await Task.sleep(for: .seconds(seconds))
        default:
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    /// The tallest vertical scroll view right of the sidebar: the transcript.
    private static func transcriptScrollView(in view: NSView?) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 200,
               scroll.convert(scroll.bounds, to: nil).minX > 200,
               document.frame.height > best?.documentView?.frame.height ?? 0 { best = scroll }
            view.subviews.forEach(visit)
        }
        view.map(visit)
        return best
    }

    private static func horizontalScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.frame.width > scroll.contentView.bounds.width + 100,
           document.frame.height <= scroll.contentView.bounds.height + 1 { return scroll }
        for subview in view.subviews { if let found = horizontalScrollView(in: subview) { return found } }
        return nil
    }

    private static let bodies = [
        "On it.",
        "Done. The **release checks** pass and the build is uploaded.",
        """
        Here is where things stand:

        - Invoices for September are sent
        - Two are overdue: *Brennan* and *Halcyon*
        - The payroll run is booked for Friday

        I will chase the overdue ones tomorrow morning.
        """,
        """
        The failing test was a race in the sync queue:

        ```swift
        queue.async { self.pending.removeAll() }
        ```

        It now clears on the queue that fills it, and all 148 tests pass.
        """,
    ]
}

private struct FrameCounter {
    var count = 0, missed = 0
    var worst: CFTimeInterval = 0
    private var last: CFTimeInterval?

    mutating func record(_ time: CFTimeInterval, nominal: CFTimeInterval) {
        defer { last = time }
        guard let last, nominal > 0 else { return }
        let interval = time - last
        count += 1
        missed += max(0, Int((interval / nominal).rounded()) - 1)
        worst = max(worst, interval)
    }
}

/// The main thread's processor time and the wall clock.
private struct Measurement {
    let wall: CFTimeInterval
    let cpu: Double

    static func now() -> Measurement {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = pthread_mach_thread_np(pthread_self())
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        let cpu = Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
        return Measurement(wall: CACurrentMediaTime(), cpu: cpu)
    }

    func report(since start: Measurement, frames: FrameCounter) -> String {
        let wall = wall - start.wall
        let busy = (cpu - start.cpu) / wall * 100
        let missed = frames.count + frames.missed > 0 ? Double(frames.missed) / Double(frames.count + frames.missed) * 100 : 0
        return String(format: "busy=%.0f%% missed=%d/%d (%.1f%%) worst=%.0fms seconds=%.1f",
            busy, frames.missed, frames.count + frames.missed, missed, frames.worst * 1000, wall)
    }
}
#endif
