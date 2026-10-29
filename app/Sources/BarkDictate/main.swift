// BarkDictate: system-wide dictation with Underdog Bark 3.0 Pro (Core ML, on-device).
//
// Hotkey: Control + Option
//   • Hold it   → records while held; words are typed live as you speak (push-to-talk).
//   • Tap it    → hands-free: keeps recording until you tap Control + Option again.
//   • Pressing any other key while holding cancels (so Ctrl+Opt shortcuts still work).
//   • Return stops dictation: the last words are typed first, then Return is pressed.
//   • 30 s without speech stops dictation automatically.
//
// While listening, a Dynamic-Island-style indicator grows out of the notch (DynamicNotchKit).

import AppKit
import AVFoundation
import CoreML
import DynamicNotchKit
import FluidAudio
import SwiftUI

// MARK: - Model

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

final class BarkModel {
    private let root: URL
    private let cache: URL
    private var short8: AsrManager?
    private var full15: AsrManager?
    private var vocabulary: [Int: String] = [:]

    init(root: URL) {
        self.root = root
        cache = root.deletingLastPathComponent().appendingPathComponent("compiled")
    }

    // Compiles each .mlpackage once and keeps the compiled copy, so later launches are fast.
    private func compiledURL(_ name: String) throws -> URL {
        let target = cache.appendingPathComponent(name + ".mlmodelc")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let package = root.appendingPathComponent(name + ".mlpackage")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw Failure("Missing model component: \(package.path)")
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let temp = try MLModel.compileModel(at: package)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    private func load(_ name: String, _ units: MLComputeUnits, function: String? = nil) throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = units
        config.functionName = function
        return try MLModel(contentsOf: compiledURL(name), configuration: config)
    }

    private func manager(function: String) throws -> AsrManager {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let models = try AsrModels(encoder: load("Encoder", .cpuAndNeuralEngine, function: function),
            preprocessor: load("Preprocessor", .cpuOnly), decoder: load("Decoder", .cpuOnly),
            joint: load("JointDecisionv3", .cpuOnly), configuration: config,
            vocabulary: vocabulary, version: .ultra)
        return AsrManager(models: models)
    }

    func prepare() throws {
        let raw = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: root.appendingPathComponent("parakeet_v3_vocab.json")))
        vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        short8 = try manager(function: "short8")
        full15 = try manager(function: "full15")
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        // 0.25 s of leading silence, as the model was evaluated.
        let samples = Array(repeating: Float(0), count: 4000) + audio
        guard let mgr = samples.count <= 128000 ? short8 : full15 else { throw Failure("Model not loaded") }
        var state = try TdtDecoderState()
        return try await mgr.transcribe(samples, decoderState: &state).text
    }
}

// Bark 3.0 Pro emits lowercase text without punctuation, so tidy it up a little.
func tidy(_ raw: String, capitalizeFirst: Bool = true) -> String {
    let spaced = raw.replacingOccurrences(of: "([a-z])([0-9])", with: "$1 $2", options: .regularExpression)
    var words = spaced.split(separator: " ").map(String.init)
    for (i, w) in words.enumerated() {
        let sentenceStart = i == 0 ? capitalizeFirst : ".?!".contains(words[i - 1].last!)
        if w == "i" || w.hasPrefix("i'") || sentenceStart { words[i] = w.prefix(1).uppercased() + w.dropFirst() }
    }
    return words.joined(separator: " ")
}

// MARK: - Recorder (mic → mono 16 kHz Float)

final class Recorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var currentLevel: Float = 0
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }
    var level: Float { lock.lock(); defer { lock.unlock() }; return currentLevel }

    func slice(_ range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return Array(samples[range.clamped(to: 0..<samples.count)])
    }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); currentLevel = 0; lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: target) else { throw Failure("No audio converter") }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard let ptr = out.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: ptr, count: Int(out.frameLength))
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            self.currentLevel = rms
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
    }

    // Test hook: append audio as if it came from the mic.
    func feed(_ chunk: ArraySlice<Float>) {
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); currentLevel = 0; lock.unlock()
    }

    // RMS of consecutive 100 ms frames in a range.
    func frameLevels(_ range: Range<Int>) -> [Float] {
        let audio = slice(range)
        return stride(from: 0, to: audio.count - 1599, by: 1600).map { i in
            sqrt(audio[i..<i + 1600].reduce(0) { $0 + $1 * $1 } / 1600)
        }
    }
}

// MARK: - Typer (types into the focused app, and fixes text it already typed)

final class Typer {
    static let marker: Int64 = 0x4241524B   // "BARK", tags our synthetic events
    private let source = CGEventSource(stateID: .privateState)
    private(set) var net = 0                // characters currently typed by us
    var dryRun = false                      // test hook: edit `screen` instead of typing
    private(set) var screen = ""
    private(set) var backspaces = 0

    func reset() { net = 0; screen = ""; backspaces = 0 }

    // Changes `old` (already on screen) into `new` with the fewest backspaces.
    func replace(_ old: String, with new: String) {
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        net += n.count - o.count
        if dryRun {
            screen = String(screen.dropLast(o.count - p)) + String(n[p...])
            backspaces += o.count - p
            return
        }
        backspace(o.count - p)
        type(String(n[p...]))
    }

    func erase(_ count: Int) { backspace(count); net -= count }

    func press(_ key: CGKeyCode) {
        guard !dryRun else { return }
        post(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true))
        post(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false))
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.flags = []     // ignore the physically held ⌃⌥
        event.setIntegerValueField(.eventSourceUserData, value: Typer.marker)
        event.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(e)
            }
        }
    }

    private func backspace(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            post(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false))
        }
    }
}

// MARK: - Live dictation
//
// Every ~0.35 s the current segment is re-transcribed. Words that two passes in a row
// agree on are typed straight away; at a pause (or after ~13 s) the segment is
// finalised and a new one starts, so each pass stays short and fast.

final class Dictation {
    private let model: BarkModel
    private let recorder: Recorder
    let typer = Typer()
    var liveTyping = true
    var onText: (String) -> Void = { _ in }
    var onSilence: () -> Void = {}
    var silenceTimeout = 30         // seconds without speech before stopping on its own

    private var running = false
    private var loop: Task<Void, Never>?
    private var committed = ""      // raw text of finished segments
    private var segStart = 0        // sample where the current segment begins
    private var lastWords: [String] = []
    private var segTyped = ""       // what is on screen for the current segment
    private var shownWords = 0      // words of the current segment on screen
    private var lastSpeech = 0      // sample where speech was last heard
    private var silenceFired = false
    private var noiseFloor: Float = 0.003

    init(model: BarkModel, recorder: Recorder) {
        self.model = model
        self.recorder = recorder
    }

    func start() throws {
        committed = ""; segStart = 0; lastWords = []; segTyped = ""; shownWords = 0
        noiseFloor = 0.003; levelHistory = []; levelsUpTo = 0
        lastSpeech = 0; silenceFired = false
        typer.reset()
        if !typer.dryRun { try recorder.start() }
        running = true
        loop = Task.detached { [self] in
            while running {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if running { await tick() }
            }
        }
    }

    /// Stops recording, finalises the last segment and returns the full tidy text.
    func finish() async -> String {
        running = false
        let t = Date()
        await loop?.value
        let waited = Date().timeIntervalSince(t)
        recorder.stop()
        let end = recorder.count
        if end - segStart > 16000 / 5 { await commit(upTo: end) }
        if ProcessInfo.processInfo.environment["BARK_DEBUG"] != nil {
            print(String(format: "finish: waited %.2fs for loop, final pass on %.1fs of audio took %.2fs",
                         waited, Double(end - segStart) / 16000, Date().timeIntervalSince(t) - waited))
        }
        return tidy(committed)
    }

    func cancel() async {
        running = false
        await loop?.value
        recorder.stop()
        if typer.net > 0 { typer.erase(typer.net) }
    }

    private func words(_ audio: [Float]) async -> [String] {
        let text = (try? await model.transcribe(audio)) ?? ""
        return text.split(separator: " ").map(String.init)
    }

    private func tick() async {
        let end = recorder.count
        guard end - segStart > 16000 * 3 / 10 else { return }
        updateNoiseFloor(upTo: end)
        if recorder.frameLevels(max(0, end - 8000)..<end).contains(where: { $0 > speechThreshold }) { lastSpeech = end }
        if ProcessInfo.processInfo.environment["BARK_DEBUG"] != nil {
            print(String(format: "tick end=%.1fs lastSpeech=%.1fs floor=%.4f thr=%.4f", Double(end) / 16000, Double(lastSpeech) / 16000, noiseFloor, speechThreshold))
        }
        if !silenceFired, end - lastSpeech > silenceTimeout * 16000 {
            silenceFired = true
            onSilence()
        }
        // Nothing but silence or background noise: don't ask the model (it would guess "Yeah").
        guard let speech = speechBounds(segStart..<end) else {
            if segTyped.isEmpty, end - segStart > 16000 { segStart = end - 4800 }   // drop the silence
            return
        }
        var words = await words(recorder.slice(trimmed(speech, segStart..<end)))
        while let last = words.last, isFiller(last) { words.removeLast() }   // noise tails like "yeah"
        lastWords = words
        onText(tidy(join(committed, words.joined(separator: " "))))
        // Type the latest guess straight away and revise it as the model hears more
        // (like voice input in chat apps); the segment's final pass settles it.
        if liveTyping { show(words) }
        if let cut = commitPoint(end) { await commit(upTo: cut) }
    }

    // MARK: Speech detection

    private var levelHistory: [Float] = []
    private var levelsUpTo = 0

    // Background level = 10th percentile of recent 100 ms frames, capped so that
    // long stretches of continuous talking can't be mistaken for background.
    private func updateNoiseFloor(upTo end: Int) {
        let start = max(levelsUpTo, end - 16000 * 2)
        let frames = recorder.frameLevels(start..<end)
        levelsUpTo = start + frames.count * 1600
        levelHistory = Array((levelHistory + frames).suffix(300))
        let sorted = levelHistory.sorted()
        noiseFloor = min(0.008, sorted.isEmpty ? 0.003 : sorted[sorted.count / 10])
    }

    private var speechThreshold: Float { max(0.012, noiseFloor * 4) }

    // First and last sample of clear speech in a range, or nil if there's under 0.3 s of it.
    private func speechBounds(_ range: Range<Int>) -> Range<Int>? {
        let frames = recorder.frameLevels(range)
        let loud = frames.indices.filter { frames[$0] > speechThreshold }
        guard loud.count >= 3, let first = loud.first, let last = loud.last else { return nil }
        return (range.lowerBound + first * 1600)..<(range.lowerBound + (last + 1) * 1600)
    }

    // The part of `range` worth transcribing: speech plus a little padding either side.
    private func trimmed(_ speech: Range<Int>, _ range: Range<Int>) -> Range<Int> {
        max(range.lowerBound, speech.lowerBound - 4800)..<min(range.upperBound, speech.upperBound + 8000)
    }

    private func isFiller(_ word: String) -> Bool {
        ["yeah", "okay", "um", "uh", "mm", "hmm", "mhm", "ah", "oh"].contains(word.lowercased().filter(\.isLetter))
    }

    // Words agree if they match ignoring case and punctuation ("So" == "so,").
    private func commonPrefix(_ a: [String], _ b: [String]) -> Int {
        func key(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        var n = 0
        while n < a.count, n < b.count, key(a[n]) == key(b[n]) { n += 1 }
        return n
    }

    private func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : (b.isEmpty ? a : a + " " + b)
    }

    // Puts the current segment's words on screen, correcting what was typed before.
    private func show(_ words: [String]) {
        let raw = words.joined(separator: " ")
        let sentenceStart = committed.isEmpty || ".?!".contains(committed.last!)
        let text = raw.isEmpty ? "" : (committed.isEmpty ? "" : " ") + tidy(raw, capitalizeFirst: sentenceStart)
        typer.replace(segTyped, with: text)
        segTyped = text
        shownWords = words.count
    }

    // Where to end the current segment: at a pause, or at the quietest spot once it gets long.
    private func commitPoint(_ end: Int) -> Int? {
        let length = end - segStart
        guard length > 16000 * 3 else { return nil }
        let frames = recorder.frameLevels(max(segStart, end - 16000 * 3)..<end)
        guard frames.count >= 5 else { return nil }
        let threshold = max(0.006, noiseFloor * 2.5)
        if frames.suffix(5).allSatisfy({ $0 < threshold }) { return end - 2400 }
        if length > 16000 * 13, let q = frames.indices.min(by: { frames[$0] < frames[$1] }) {
            return end - (frames.count - q) * 1600 + 800
        }
        return nil
    }

    private func commit(upTo cut: Int) async {
        var final: [String] = []
        if let speech = speechBounds(segStart..<cut) {
            final = await words(recorder.slice(trimmed(speech, segStart..<cut)))
            // A lone "yeah"/"um" from under a second of sound is almost always noise.
            if final.allSatisfy(isFiller), speech.count < 16000 { final = [] }
        } else if !segTyped.isEmpty {
            // Words are already on screen; never wipe them on a borderline level reading.
            final = await words(recorder.slice(segStart..<cut))
        }
        if liveTyping { show(final) }
        committed = join(committed, final.joined(separator: " "))
        segStart = cut
        lastWords = []
        segTyped = ""
        shownWords = 0
        onText(tidy(committed))
    }
}

// MARK: - Island UI

final class IslandModel: ObservableObject {
    enum Phase { case listening, handsFree, finishing, done }
    @Published var phase: Phase = .listening
    @Published var text = ""
    @Published var notice: String?
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 14)

    func push(_ rms: Float) {
        let v = CGFloat(min(1, pow(Double(rms) * 14, 0.7)))
        levels.removeFirst()
        levels.append(v)
    }
}

struct RecordingDot: View {
    @ObservedObject var model: IslandModel
    var frozenPulse: CGFloat? = nil   // fixed point in the pulse, for rendering stills
    @State private var pulse = false

    var body: some View {
        let p = frozenPulse ?? (pulse ? 1 : 0)
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14)
                .scaleEffect(0.7 + 0.55 * p).opacity(1 - p)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var color: Color { model.phase == .handsFree ? .orange : .red }
}

struct Waveform: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        Group {
            switch model.phase {
            case .finishing:
                ProgressView().controlSize(.small).tint(.white)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .font(.system(size: 14, weight: .semibold))
                    .transition(.scale.combined(with: .opacity))
            default:
                HStack(spacing: 2) {
                    ForEach(model.levels.indices, id: \.self) { i in
                        Capsule()
                            .fill(LinearGradient(colors: [.orange, .pink], startPoint: .bottom, endPoint: .top))
                            .frame(width: 2.5, height: 3 + model.levels[i] * 13)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: model.levels)
            }
        }
        .frame(height: 18)
    }
}

struct FloatingContent: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 10) {
            RecordingDot(model: model)
            Text(model.notice ?? (model.text.isEmpty ? "Listening…" : model.text))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.notice != nil ? .yellow : (model.text.isEmpty ? .secondary : .primary))
                .lineLimit(1).truncationMode(.head)
                .frame(width: 280, alignment: .leading)
            Waveform(model: model)
        }
        .padding(.horizontal, 6)
    }
}

@MainActor
final class Island {
    let model = IslandModel()
    private lazy var notch: DynamicNotch<FloatingContent, AnyView, AnyView> = DynamicNotch(hoverBehavior: [], style: .auto) { [model] in
        FloatingContent(model: model)
    } compactLeading: { [model] in
        AnyView(RecordingDot(model: model).padding(.leading, 4))
    } compactTrailing: { [model] in
        AnyView(Waveform(model: model).padding(.trailing, 4))
    }
    private var levelTimer: Timer?

    private var hasNotch: Bool { (NSScreen.screens.first?.safeAreaInsets.top ?? 0) > 0 }

    func show(level: @escaping () -> Float, notice: String? = nil) {
        model.phase = .listening
        model.text = ""
        model.notice = notice
        model.levels = Array(repeating: 0, count: model.levels.count)
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.push(level()) }
        }
        Task { hasNotch && notice == nil ? await notch.compact() : await notch.expand() }
    }

    func finishing() {
        levelTimer?.invalidate()
        withAnimation { model.phase = .finishing }
    }

    func done(notice: String? = nil) {
        if let notice { model.notice = notice }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { model.phase = .done }
        Task {
            try? await Task.sleep(nanoseconds: model.notice == nil ? 700_000_000 : 2_500_000_000)
            await notch.hide()
        }
    }

    func hide() {
        levelTimer?.invalidate()
        Task { await notch.hide() }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case loading, idle, recording, transcribing }

    private var statusItem: NSStatusItem!
    private let model = BarkModel(root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("BarkDictate/model/coreml"))
    private let recorder = Recorder()
    private lazy var dictation = Dictation(model: model, recorder: recorder)
    private var island: Island!
    private var state: State = .loading { didSet { updateIcon() } }

    private var comboDown = false
    private var comboDownAt = Date()
    private var otherKeyPressed = false
    private var handsFree = false
    private let tapThreshold: TimeInterval = 0.3
    private var monitors: [Any] = []
    private var liveTypingItem: NSMenuItem!

    private var liveTyping: Bool {
        get { UserDefaults.standard.object(forKey: "liveTyping") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveTyping") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = Island()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "BarkDictate: hold or tap ⌃⌥ to dictate", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        liveTypingItem = menu.addItem(withTitle: "Type while I speak", action: #selector(toggleLiveTyping), keyEquivalent: "")
        liveTypingItem.state = liveTyping ? .on : .off
        menu.addItem(withTitle: "Accessibility settings…", action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        updateIcon()

        dictation.onText = { [weak self] text in
            DispatchQueue.main.async { self?.island.model.text = text }
        }
        dictation.onSilence = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.state == .recording else { return }
                self.log("Stopping after \(self.dictation.silenceTimeout) s of silence")
                self.handsFree = false
                self.finish()
            }
        }
        installReturnTap()

        // Prompts for Accessibility (needed to see ⌃⌥ globally and to type).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { log("Waiting for Accessibility permission") }
        AVCaptureDevice.requestAccess(for: .audio) { ok in self.log("Microphone access: \(ok)") }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0) } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.keyDown($0) } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0); return $0 } as Any)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let t = Date()
                try self.model.prepare()
                self.log(String(format: "Model ready in %.1fs", Date().timeIntervalSince(t)))
                DispatchQueue.main.async { self.state = .idle }
            } catch {
                self.log("Model load failed: \(error)")
            }
        }
    }

    // MARK: Hotkey

    private func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        let isCombo = flags == [.control, .option]
        if isCombo && !comboDown {
            comboDown = true
            comboDownAt = Date()
            otherKeyPressed = false
            if handsFree { handsFree = false; finish() }   // second tap ends hands-free mode
            else if state == .idle { begin() }
        } else if !isCombo && comboDown {
            comboDown = false
            guard state == .recording, !handsFree else { return }
            if otherKeyPressed { cancel() }
            else if Date().timeIntervalSince(comboDownAt) < tapThreshold {
                handsFree = true
                island.model.phase = .handsFree
                updateIcon()
            }
            else { finish() }
        }
    }

    private func keyDown(_ event: NSEvent) {
        // Our own typing is tagged; ignore it.
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Typer.marker { return }
        // Return ends dictation (only reaches here if the Return tap couldn't be installed).
        if state == .recording, [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .shift]).isEmpty {
            handsFree = false
            finish()
            return
        }
        // ⌃⌥ + some key = a shortcut for another app, not dictation.
        if comboDown && state == .recording && !handsFree { otherKeyPressed = true }
    }

    // MARK: Return key
    //
    // While dictating, Return is held back until the last words are typed, then pressed
    // for you, so e.g. a chat message isn't sent without its final words.

    private var returnTap: CFMachPort?
    private var swallowReturnUp = false

    private func installReturnTap() {
        guard returnTap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            return MainActor.assumeIsolated { me.handleTap(type, event) }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("Couldn't install the Return key tap")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        returnTap = tap
    }

    private func handleTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let returnTap { CGEvent.tapEnable(tap: returnTap, enable: true) }
            return pass
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == 36 || code == 76,
              event.getIntegerValueField(.eventSourceUserData) != Typer.marker else { return pass }
        if type == .keyUp, swallowReturnUp { swallowReturnUp = false; return nil }
        // Shift/⌘+Return (new line, etc.) pass through untouched.
        guard type == .keyDown, state == .recording,
              event.flags.intersection([.maskShift, .maskCommand]).isEmpty else { return pass }
        swallowReturnUp = true
        handsFree = false
        finish(pressReturn: true)
        return nil
    }

    // MARK: Flow

    private var canType = false

    private func begin() {
        do {
            // Without Accessibility, macOS silently drops our keystrokes, so fall back to the clipboard.
            canType = AXIsProcessTrusted()
            if canType { installReturnTap() }
            if !canType { log("Accessibility is off: text will go to the clipboard") }
            dictation.liveTyping = liveTyping && canType
            try dictation.start()
            state = .recording
            island.show(level: { [recorder] in recorder.level },
                        notice: canType ? nil : "Turn on Accessibility for BarkDictate to type")
            NSSound(named: "Tink")?.play()
        } catch {
            log("Mic start failed: \(error)")
        }
    }

    private func cancel() {
        state = .transcribing
        island.hide()
        Task {
            await dictation.cancel()
            await MainActor.run { self.state = .idle }
        }
    }

    private func finish(pressReturn: Bool = false) {
        NSSound(named: "Pop")?.play()
        state = .transcribing
        island.finishing()
        let t = Date()
        Task {
            let text = await dictation.finish()
            self.log(String(format: "finished in %.2fs after release: %@", Date().timeIntervalSince(t), text))
            await MainActor.run {
                if !self.canType && !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.island.done(notice: "Copied to clipboard. Press ⌘V to paste")
                } else {
                    if !self.liveTyping && !text.isEmpty { self.paste(text) }
                    if pressReturn { self.dictation.typer.press(36) }
                    if text.isEmpty { self.island.hide() } else { self.island.done() }
                }
                self.state = .idle
            }
        }
    }

    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)

        // Put the previous clipboard back once the paste has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !saved.isEmpty else { return }
            pb.clearContents()
            pb.writeObjects(saved.map { d in
                let item = NSPasteboardItem()
                for (t, v) in d { item.setData(v, forType: t) }
                return item
            })
        }
    }

    // MARK: UI

    private func updateIcon() {
        let (symbol, tip): (String, String) = switch state {
        case .loading: ("hourglass", "Loading Bark 3.0 Pro…")
        case .idle: ("mic", "Ready: hold or tap ⌃⌥")
        case .recording: ("mic.fill", handsFree ? "Listening (tap ⌃⌥ to stop)" : "Listening…")
        case .transcribing: ("ellipsis.circle", "Transcribing…")
        }
        DispatchQueue.main.async {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            image?.isTemplate = self.state != .recording
            self.statusItem.button?.image = self.state == .recording
                ? image?.withSymbolConfiguration(.init(paletteColors: [.systemRed])) : image
            self.statusItem.button?.toolTip = tip
        }
    }

    @objc private func toggleLiveTyping() {
        liveTyping.toggle()
        liveTypingItem.state = liveTyping ? .on : .off
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("BarkDictate/bark.log")

    nonisolated private func log(_ message: String) {
        let line = ("[\(Date())] " + message + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: logURL) }
    }
}

// `BarkDictate --render-demo DIR` draws the README images from the real island views.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-demo" {
    MainActor.assumeIsolated { renderDemo(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
    exit(0)
}

// `BarkDictate --simulate x.wav` streams a WAV through live dictation in real time and
// prints what would be typed, without touching the keyboard (for testing).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--simulate" {
    let model = BarkModel(root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("BarkDictate/model/coreml"))
    let recorder = Recorder()
    let dictation = Dictation(model: model, recorder: recorder)
    dictation.typer.dryRun = true
    if let secs = ProcessInfo.processInfo.environment["BARK_SILENCE_SECONDS"].flatMap(Int.init) {
        dictation.silenceTimeout = secs
    }
    final class Flag: @unchecked Sendable { var hit = false }
    let silence = Flag()
    dictation.onSilence = { silence.hit = true }
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            try model.prepare()
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let audio = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            try dictation.start()
            var lastScreen = ""
            let t0 = Date()
            for start in stride(from: 0, to: audio.count, by: 1024) {
                if silence.hit {
                    print(String(format: "%5.1fs  auto-stop: no speech for %d s", Date().timeIntervalSince(t0), dictation.silenceTimeout))
                    break
                }
                recorder.feed(audio[start..<min(start + 1024, audio.count)])
                try? await Task.sleep(nanoseconds: 64_000_000)
                let screen = dictation.typer.screen
                if screen != lastScreen {
                    print(String(format: "%5.1fs  %@", Date().timeIntervalSince(t0), screen))
                    lastScreen = screen
                }
            }
            let t = Date()
            let final = await dictation.finish()
            print(String(format: "release → final in %.2fs", Date().timeIntervalSince(t)))
            print("screen: \(dictation.typer.screen)")
            print("final:  \(final)")
            print("match: \(dictation.typer.screen == final)  backspaces: \(dictation.typer.backspaces)")
        } catch { print("error: \(error)") }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

// `BarkDictate --file x.wav` transcribes a mono 16 kHz WAV and exits (for testing).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--file" {
    let model = BarkModel(root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("BarkDictate/model/coreml"))
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            var t = Date()
            try model.prepare()
            print(String(format: "load %.2fs", Date().timeIntervalSince(t)))
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let audio = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            for _ in 0..<2 {
                t = Date()
                let text = try await model.transcribe(audio)
                print(String(format: "%.1fs audio in %.2fs: %@", Double(audio.count) / 16000, Date().timeIntervalSince(t), tidy(text)))
            }
        } catch { print("error: \(error)") }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
