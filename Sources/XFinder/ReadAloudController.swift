@preconcurrency import AVFoundation
import Foundation

struct ReadAloudSpeechRequest: Equatable, Sendable {
    let id: UUID
    let text: String
    let rateMultiplier: Float
    let languageCode: String?
}

@MainActor
protocol ReadAloudSpeechEngineDelegate: AnyObject {
    func speechEngineDidFinish(requestID: UUID)
    func speechEngineDidCancel(requestID: UUID)
    func speechEngineDidFallback(requestID: UUID, reason: String)
}

extension ReadAloudSpeechEngineDelegate {
    func speechEngineDidFallback(requestID: UUID, reason: String) {}
}

@MainActor
protocol ReadAloudSpeechEngine: AnyObject {
    var delegate: (any ReadAloudSpeechEngineDelegate)? { get set }
    func speak(_ request: ReadAloudSpeechRequest)
    func pause() -> Bool
    func resume() -> Bool
    func stop() -> Bool
}

@MainActor
final class SystemReadAloudSpeechEngine: NSObject, ReadAloudSpeechEngine, AVSpeechSynthesizerDelegate {
    weak var delegate: (any ReadAloudSpeechEngineDelegate)?

    private let synthesizer = AVSpeechSynthesizer()
    private var activeRequestID: UUID?
    private var activeUtteranceID: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ request: ReadAloudSpeechRequest) {
        activeRequestID = request.id
        let utterance = AVSpeechUtterance(string: request.text)
        activeUtteranceID = ObjectIdentifier(utterance)
        utterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            AVSpeechUtteranceDefaultSpeechRate * request.rateMultiplier
        )
        if let languageCode = request.languageCode,
            let voice = AVSpeechSynthesisVoice(language: languageCode)
        {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func pause() -> Bool {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() -> Bool {
        synthesizer.continueSpeaking()
    }

    func stop() -> Bool {
        activeRequestID = nil
        activeUtteranceID = nil
        return synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finish(utteranceID: utteranceID, wasCancelled: false)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finish(utteranceID: utteranceID, wasCancelled: true)
        }
    }

    private func finish(utteranceID: ObjectIdentifier, wasCancelled: Bool) {
        guard activeUtteranceID == utteranceID, let requestID = activeRequestID else { return }
        activeRequestID = nil
        activeUtteranceID = nil
        if wasCancelled {
            delegate?.speechEngineDidCancel(requestID: requestID)
        } else {
            delegate?.speechEngineDidFinish(requestID: requestID)
        }
    }
}

typealias ReadAloudLoader = @Sendable (URL, ReadAloudFileKind, ReadAloudLimits) async throws -> ReadAloudDocument

@MainActor
final class ReadAloudController: ObservableObject, ReadAloudSpeechEngineDelegate {
    @Published private(set) var phase: ReadAloudPhase = .idle
    @Published private(set) var sourceURL: URL?
    @Published private(set) var currentChunkNumber = 0
    @Published private(set) var totalChunkCount = 0
    @Published private(set) var speed: ReadAloudSpeed = .normal

    var onEvent: ((ReadAloudEvent) -> Void)?

    private let engine: any ReadAloudSpeechEngine
    private let loader: ReadAloudLoader
    private let limits: ReadAloudLimits
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var chunks: [String] = []
    private var currentChunkIndex = 0
    private var currentRequestID: UUID?

    init(
        engine: (any ReadAloudSpeechEngine)? = nil,
        limits: ReadAloudLimits = .standard,
        loader: @escaping ReadAloudLoader = { url, kind, limits in
            try await ReadableContentService.load(from: url, kind: kind, limits: limits)
        }
    ) {
        let resolvedEngine = engine ?? SystemReadAloudSpeechEngine()
        self.engine = resolvedEngine
        self.loader = loader
        self.limits = limits
        resolvedEngine.delegate = self
    }

    var isActive: Bool {
        phase != .idle
    }

    var canPauseOrResume: Bool {
        phase == .playing || phase == .paused
    }

    var sourceName: String? {
        sourceURL?.lastPathComponent
    }

    func isReading(_ url: URL) -> Bool {
        sourceURL?.standardizedFileURL == url.standardizedFileURL && isActive
    }

    func start(url: URL, kind: ReadAloudFileKind) {
        cancelCurrentWork()
        loadGeneration += 1
        let generation = loadGeneration
        sourceURL = url
        currentChunkNumber = 0
        totalChunkCount = 0
        phase = .loading
        onEvent?(.preparing(url.lastPathComponent))

        loadTask = Task { [weak self, loader, limits] in
            do {
                let document = try await loader(url, kind, limits)
                try Task.checkCancellation()
                guard let self, self.loadGeneration == generation else { return }
                self.chunks = document.chunks
                self.totalChunkCount = document.chunks.count
                self.currentChunkIndex = 0
                self.onEvent?(.started(url.lastPathComponent, truncated: document.wasTruncated))
                self.speakCurrentChunk()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.loadGeneration == generation else { return }
                self.resetSession()
                self.onEvent?(.failed("\(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }
    }

    func togglePause() {
        switch phase {
        case .playing:
            if engine.pause() { phase = .paused }
        case .paused:
            if engine.resume() { phase = .playing }
        case .idle, .loading:
            break
        }
    }

    func restart() {
        guard !chunks.isEmpty else { return }
        _ = engine.stop()
        currentRequestID = nil
        currentChunkIndex = 0
        speakCurrentChunk()
    }

    func stop() {
        guard let sourceName else { return }
        cancelCurrentWork()
        resetSession()
        onEvent?(.stopped(sourceName))
    }

    func setSpeed(_ speed: ReadAloudSpeed) {
        self.speed = speed
    }

    func speechEngineDidFinish(requestID: UUID) {
        guard requestID == currentRequestID, phase == .playing else { return }
        currentRequestID = nil
        currentChunkIndex += 1
        guard currentChunkIndex < chunks.count else {
            let completedName = sourceName ?? "File"
            resetSession()
            onEvent?(.completed(completedName))
            return
        }
        speakCurrentChunk()
    }

    func speechEngineDidCancel(requestID: UUID) {
        guard requestID == currentRequestID else { return }
        currentRequestID = nil
        let cancelledName = sourceName ?? "File"
        resetSession()
        onEvent?(.failed("\(cancelledName): speech synthesis was cancelled."))
    }

    func speechEngineDidFallback(requestID: UUID, reason: String) {
        guard requestID == currentRequestID else { return }
        onEvent?(.fallback(reason))
    }

    private func speakCurrentChunk() {
        guard chunks.indices.contains(currentChunkIndex) else { return }
        let text = chunks[currentChunkIndex]
        let request = ReadAloudSpeechRequest(
            id: UUID(),
            text: text,
            rateMultiplier: speed.multiplier,
            languageCode: ReadAloudTextLogic.preferredLanguageCode(for: text)
        )
        currentRequestID = request.id
        currentChunkNumber = currentChunkIndex + 1
        phase = .playing
        engine.speak(request)
    }

    private func cancelCurrentWork() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        _ = engine.stop()
        currentRequestID = nil
    }

    private func resetSession() {
        loadTask = nil
        chunks.removeAll(keepingCapacity: false)
        currentChunkIndex = 0
        currentChunkNumber = 0
        totalChunkCount = 0
        sourceURL = nil
        phase = .idle
    }
}
