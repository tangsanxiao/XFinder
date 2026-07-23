import Foundation

enum DoubaoTTSClientError: Error, Equatable, LocalizedError {
    case notConfigured
    case invalidRequest
    case badResponse(Int, String)
    case service(String)
    case invalidAudio
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Doubao Speech is not fully configured."
        case .invalidRequest:
            return "The Doubao Speech request could not be created."
        case .badResponse(let code, let message):
            return "Doubao Speech returned HTTP \(code): \(message.prefix(160))"
        case .service(let message):
            return "Doubao Speech rejected the request: \(message.prefix(160))"
        case .invalidAudio:
            return "Doubao Speech returned no playable audio."
        case .responseTooLarge:
            return "Doubao Speech returned more audio than the safety limit allows."
        }
    }
}

private struct DoubaoAudioCacheKey: Hashable, Sendable {
    let text: String
    let speed: Float
    let resourceID: String
    let voiceID: String
}

actor DoubaoAudioCache {
    private struct Entry: Sendable {
        let data: Data
        let insertion: UInt64
    }

    private let maximumBytes: Int
    private var entries: [DoubaoAudioCacheKey: Entry] = [:]
    private var totalBytes = 0
    private var insertion = UInt64.zero

    init(maximumBytes: Int = 12 * 1_024 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    fileprivate func data(for key: DoubaoAudioCacheKey) -> Data? {
        entries[key]?.data
    }

    fileprivate func insert(_ data: Data, for key: DoubaoAudioCacheKey) {
        guard data.count <= maximumBytes else { return }
        if let existing = entries.removeValue(forKey: key) {
            totalBytes -= existing.data.count
        }
        insertion &+= 1
        entries[key] = Entry(data: data, insertion: insertion)
        totalBytes += data.count

        while totalBytes > maximumBytes,
            let oldest = entries.min(by: { $0.value.insertion < $1.value.insertion })
        {
            entries.removeValue(forKey: oldest.key)
            totalBytes -= oldest.value.data.count
        }
    }
}

struct DoubaoTTSClient: Sendable {
    static let endpoint = URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse")!
    static let maximumResponseBytes = 20 * 1_024 * 1_024
    static let maximumAudioBytes = 12 * 1_024 * 1_024

    private let session: URLSession
    private let cache: DoubaoAudioCache

    init(session: URLSession = .shared, cache: DoubaoAudioCache = DoubaoAudioCache()) {
        self.session = session
        self.cache = cache
    }

    func synthesize(text: String, speed: Float, config: DoubaoTTSConfig) async throws -> Data {
        let normalizedSpeed = min(2, max(0.5, speed))
        let key = DoubaoAudioCacheKey(
            text: text,
            speed: normalizedSpeed,
            resourceID: config.resourceID,
            voiceID: config.voiceID
        )
        if let cached = await cache.data(for: key) { return cached }

        let request = try Self.makeRequest(text: text, speed: normalizedSpeed, config: config)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard data.count <= Self.maximumResponseBytes else { throw DoubaoTTSClientError.responseTooLarge }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw DoubaoTTSClientError.badResponse(statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }

        let audio = try await Task.detached(priority: .userInitiated) {
            try Self.parseSSEAudio(data, maximumAudioBytes: Self.maximumAudioBytes)
        }.value
        try Task.checkCancellation()
        await cache.insert(audio, for: key)
        return audio
    }

    /// Pure request construction keeps credentials, endpoint, and payload
    /// behavior covered without issuing a network request in tests.
    static func makeRequest(text: String, speed: Float, config: DoubaoTTSConfig) throws -> URLRequest {
        guard config.isUsable, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoubaoTTSClientError.notConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Api-Key")
        request.setValue(
            config.resourceID.trimmingCharacters(in: .whitespacesAndNewlines),
            forHTTPHeaderField: "X-Api-Resource-Id"
        )
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")

        let payload: [String: Any] = [
            "user": ["uid": "xfinder-local"],
            "req_params": [
                "text": text,
                "speaker": config.voiceID.trimmingCharacters(in: .whitespacesAndNewlines),
                "speed_ratio": min(2, max(0.5, speed)),
                "audio_params": [
                    "format": "mp3",
                    "sample_rate": 24_000,
                ],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload) else { throw DoubaoTTSClientError.invalidRequest }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// V3 SSE frames carry one JSON object per `data:` line. Audio frames use
    /// a Base64 `data` field; event 153 is the service failure frame.
    static func parseSSEAudio(_ data: Data, maximumAudioBytes: Int = maximumAudioBytes) throws -> Data {
        guard data.count <= maximumResponseBytes else { throw DoubaoTTSClientError.responseTooLarge }
        let text = String(decoding: data, as: UTF8.self)
        var currentEvent: Int?
        var audio = Data()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("event:") {
                currentEvent = Int(line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard line.hasPrefix("data:") else {
                if line.isEmpty { currentEvent = nil }
                continue
            }

            let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let jsonData = json.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { continue }

            if currentEvent == 153 {
                throw DoubaoTTSClientError.service(object["message"] as? String ?? "Unknown service error")
            }
            if let encoded = object["data"] as? String,
                let chunk = Data(base64Encoded: encoded), !chunk.isEmpty
            {
                guard audio.count + chunk.count <= maximumAudioBytes else {
                    throw DoubaoTTSClientError.responseTooLarge
                }
                audio.append(chunk)
            }
        }

        guard !audio.isEmpty else { throw DoubaoTTSClientError.invalidAudio }
        return audio
    }
}
