@preconcurrency import AVFoundation
import Foundation

typealias DoubaoSpeechSynthesizer = @Sendable (String, Float, DoubaoTTSConfig) async throws -> Data

/// Uses Doubao only for explicit Read Aloud requests. A failed cloud request
/// immediately falls back to the system engine and opens a short circuit so a
/// long document cannot trigger one failing network request per paragraph.
@MainActor
final class HybridReadAloudSpeechEngine: NSObject, ReadAloudSpeechEngine, ReadAloudSpeechEngineDelegate,
    AVAudioPlayerDelegate
{
    weak var delegate: (any ReadAloudSpeechEngineDelegate)?

    private let systemEngine: any ReadAloudSpeechEngine
    private let configProvider: @MainActor () -> DoubaoTTSConfig
    private let synthesizer: DoubaoSpeechSynthesizer
    private var synthesisTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var activeAudioPlayerID: ObjectIdentifier?
    private var activeRequest: ReadAloudSpeechRequest?
    private var usesSystemEngine = false
    private var lastConfig: DoubaoTTSConfig?
    private var cloudCooldownUntil: Date?
    private var reportedFallbackForCurrentConfig = false

    init(
        systemEngine: (any ReadAloudSpeechEngine)? = nil,
        configProvider: @escaping @MainActor () -> DoubaoTTSConfig,
        synthesizer: DoubaoSpeechSynthesizer? = nil
    ) {
        let client = DoubaoTTSClient()
        self.systemEngine = systemEngine ?? SystemReadAloudSpeechEngine()
        self.configProvider = configProvider
        self.synthesizer =
            synthesizer ?? { text, speed, config in
                try await client.synthesize(text: text, speed: speed, config: config)
            }
        super.init()
        self.systemEngine.delegate = self
    }

    func speak(_ request: ReadAloudSpeechRequest) {
        haltOutput()
        activeRequest = request

        let config = configProvider()
        if lastConfig != config {
            lastConfig = config
            cloudCooldownUntil = nil
            reportedFallbackForCurrentConfig = false
        }

        guard config.enabled else {
            speakWithSystem(request)
            return
        }
        guard config.isUsable else {
            fallBackToSystem(request, reason: "Doubao Speech settings are incomplete.")
            return
        }
        if let cloudCooldownUntil, cloudCooldownUntil > Date() {
            speakWithSystem(request)
            return
        }

        synthesisTask = Task { [weak self, synthesizer] in
            do {
                let data = try await synthesizer(request.text, request.rateMultiplier, config)
                try Task.checkCancellation()
                guard let self, self.activeRequest?.id == request.id else { return }
                self.playCloudAudio(data, for: request)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeRequest?.id == request.id else { return }
                self.fallBackToSystem(request, reason: error.localizedDescription)
            }
        }
    }

    func pause() -> Bool {
        if usesSystemEngine { return systemEngine.pause() }
        guard let audioPlayer, audioPlayer.isPlaying else { return false }
        audioPlayer.pause()
        return true
    }

    func resume() -> Bool {
        if usesSystemEngine { return systemEngine.resume() }
        guard let audioPlayer, !audioPlayer.isPlaying else { return false }
        return audioPlayer.play()
    }

    func stop() -> Bool {
        let wasActive = activeRequest != nil
        activeRequest = nil
        haltOutput()
        return wasActive
    }

    func speechEngineDidFinish(requestID: UUID) {
        guard usesSystemEngine, activeRequest?.id == requestID else { return }
        activeRequest = nil
        usesSystemEngine = false
        delegate?.speechEngineDidFinish(requestID: requestID)
    }

    func speechEngineDidCancel(requestID: UUID) {
        guard usesSystemEngine, activeRequest?.id == requestID else { return }
        activeRequest = nil
        usesSystemEngine = false
        delegate?.speechEngineDidCancel(requestID: requestID)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishCloudAudio(playerID: playerID, succeeded: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let playerID = ObjectIdentifier(player)
        let message = error?.localizedDescription ?? "The downloaded audio could not be decoded."
        Task { @MainActor [weak self] in
            self?.handleCloudDecodeError(playerID: playerID, message: message)
        }
    }

    private func playCloudAudio(_ data: Data, for request: ReadAloudSpeechRequest) {
        synthesisTask = nil
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else { throw DoubaoTTSClientError.invalidAudio }
            audioPlayer = player
            activeAudioPlayerID = ObjectIdentifier(player)
            cloudCooldownUntil = nil
            usesSystemEngine = false
        } catch {
            fallBackToSystem(request, reason: error.localizedDescription)
        }
    }

    private func finishCloudAudio(playerID: ObjectIdentifier, succeeded: Bool) {
        guard activeAudioPlayerID == playerID, let request = activeRequest else { return }
        audioPlayer = nil
        activeAudioPlayerID = nil
        activeRequest = nil
        if succeeded {
            delegate?.speechEngineDidFinish(requestID: request.id)
        } else {
            delegate?.speechEngineDidCancel(requestID: request.id)
        }
    }

    private func handleCloudDecodeError(playerID: ObjectIdentifier, message: String) {
        guard activeAudioPlayerID == playerID, let request = activeRequest else { return }
        audioPlayer = nil
        activeAudioPlayerID = nil
        fallBackToSystem(request, reason: message)
    }

    private func fallBackToSystem(_ request: ReadAloudSpeechRequest, reason: String) {
        synthesisTask?.cancel()
        synthesisTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeAudioPlayerID = nil
        cloudCooldownUntil = Date().addingTimeInterval(60)
        if !reportedFallbackForCurrentConfig {
            reportedFallbackForCurrentConfig = true
            delegate?.speechEngineDidFallback(requestID: request.id, reason: reason)
        }
        speakWithSystem(request)
    }

    private func speakWithSystem(_ request: ReadAloudSpeechRequest) {
        usesSystemEngine = true
        systemEngine.speak(request)
    }

    private func haltOutput() {
        synthesisTask?.cancel()
        synthesisTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeAudioPlayerID = nil
        _ = systemEngine.stop()
        usesSystemEngine = false
    }
}
