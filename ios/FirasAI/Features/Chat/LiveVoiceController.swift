@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit

nonisolated enum LiveVoiceConnectionState: Equatable, Sendable {
    case idle
    case requestingPermission
    case connecting
    case connected
    case ended
    case failed(String)
}

private nonisolated struct LiveVoiceTokenRequest: Encodable, Sendable {
    let prefer: String
    let voice: String
}

private nonisolated struct LiveVoiceToken: Decodable, Sendable {
    let provider: String
    let token: String
    let model: String
    let maxMs: Int
    let guest: Bool
    let startWithinMs: Int
}

private nonisolated enum GeminiLiveEvent: Sendable {
    case connected(model: String, maximumDuration: Duration)
    case interrupted
    case audio(Data)
    case ended
    case failed(String)
}

private actor LiveVoiceTokenClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    func mint(voice: String) async throws -> LiveVoiceToken {
        let endpoint = baseURL.appending(path: "api/live/token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LiveVoiceTokenRequest(prefer: "gemini", voice: voice)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.httpStatus(
                code: http.statusCode,
                message: Self.safeError(from: data, statusCode: http.statusCode)
            )
        }

        let token = try JSONDecoder().decode(LiveVoiceToken.self, from: data)
        guard token.provider == "gemini", !token.token.isEmpty else {
            throw APIError.invalidResponse
        }
        return token
    }

    private static func safeError(from data: Data, statusCode: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error"] as? String
        else {
            return HTTPURLResponse.localizedString(forStatusCode: statusCode)
        }

        switch code {
        case "signin_required":
            return "voice_signin_required"
        case "quota", "rate limited", "rate_limited":
            return "voice_quota_reached"
        case "no_engine", "mint_failed", "unreachable":
            return "voice_service_unavailable"
        default:
            return "voice_connection_failed"
        }
    }
}

private actor GeminiLiveTransport {
    typealias EventHandler = @MainActor @Sendable (GeminiLiveEvent) -> Void

    private let handler: EventHandler
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var hardLimitTask: Task<Void, Never>?
    private var ready = false
    private var muted = false
    private var closed = false

    init(handler: @escaping EventHandler) {
        self.handler = handler
    }

    func connect(with token: LiveVoiceToken, language: AppLanguage) async throws {
        guard socket == nil else { return }
        guard var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
        ) else {
            throw APIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "access_token", value: token.token)]
        guard let url = components.url else { throw APIError.invalidURL }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.socket = socket
        closed = false
        socket.resume()

        try await sendSetup(model: token.model, language: language)

        let ceiling = max(10_000, token.maxMs - 1_500)
        hardLimitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ceiling))
            guard !Task.isCancelled else { return }
            await self?.finish(notify: true)
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(model: token.model, maxMs: token.maxMs)
        }
    }

    func setMuted(_ value: Bool) {
        muted = value
    }

    func sendPCM16(_ data: Data) async {
        guard ready, !muted, !closed, let socket else { return }
        let payload: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": data.base64EncodedString(),
                ],
            ],
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: encoded, encoding: .utf8)
        else { return }
        try? await socket.send(.string(text))
    }

    func close() async {
        await finish(notify: false)
    }

    private func sendSetup(model: String, language: AppLanguage) async throws {
        guard let socket else { throw APIError.invalidResponse }
        let interfaceLanguage = language == .arabic ? "Arabic" : "English"
        let instruction = """
        You are Firas on a live voice call. Speak naturally in short conversational turns. \
        Answer in the same language and dialect the caller uses; Iraqi Arabic must remain Iraqi \
        Arabic. Never read markdown or punctuation aloud. If interrupted, stop immediately and \
        listen. The interface language is \(interfaceLanguage), but the caller's language wins.
        """
        let payload: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": ["voiceName": "Charon"],
                        ],
                    ],
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "prefixPaddingMs": 300,
                        "silenceDurationMs": 800,
                    ],
                ],
                "systemInstruction": ["parts": [["text": instruction]]],
            ],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw APIError.encoding("voice_setup_failed")
        }
        try await socket.send(.string(text))
    }

    private func receiveLoop(model: String, maxMs: Int) async {
        guard let socket else { return }
        do {
            while !Task.isCancelled, !closed {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value):
                    data = value
                case .string(let value):
                    data = Data(value.utf8)
                @unknown default:
                    continue
                }
                await consume(data, model: model, maxMs: maxMs)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !closed else { return }
            await handler(.failed("voice_connection_lost"))
            await finish(notify: false)
        }
    }

    private func consume(_ data: Data, model: String, maxMs: Int) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if object["setupComplete"] != nil {
            ready = true
            await handler(
                .connected(
                    model: model,
                    maximumDuration: .milliseconds(maxMs)
                )
            )
        }

        if object["goAway"] != nil {
            await finish(notify: true)
            return
        }

        guard let serverContent = object["serverContent"] as? [String: Any] else { return }
        if serverContent["interrupted"] as? Bool == true {
            await handler(.interrupted)
        }

        guard let modelTurn = serverContent["modelTurn"] as? [String: Any],
              let parts = modelTurn["parts"] as? [[String: Any]]
        else { return }

        for part in parts {
            guard let inlineData = part["inlineData"] as? [String: Any],
                  let base64 = inlineData["data"] as? String,
                  let mimeType = inlineData["mimeType"] as? String,
                  mimeType.localizedCaseInsensitiveContains("audio"),
                  let audio = Data(base64Encoded: base64),
                  !audio.isEmpty
            else { continue }
            await handler(.audio(audio))
        }
    }

    private func finish(notify: Bool) async {
        guard !closed else { return }
        closed = true
        ready = false
        receiveTask?.cancel()
        hardLimitTask?.cancel()
        receiveTask = nil
        hardLimitTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        if notify {
            await handler(.ended)
        }
    }
}

@MainActor
@Observable
final class LiveVoiceController {
    private(set) var connectionState: LiveVoiceConnectionState = .idle
    private(set) var phase: VoiceCallPhase = .listening
    private(set) var audioLevel: Double = 0
    private(set) var modelName = ""
    private(set) var startedAt: Date?
    private(set) var maximumDuration: Duration?
    private(set) var isMuted = false
    private(set) var usesSpeaker = true

    @ObservationIgnored private let tokenClient: LiveVoiceTokenClient
    @ObservationIgnored private var transport: GeminiLiveTransport?
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var speechSettleTask: Task<Void, Never>?
    @ObservationIgnored private var outputDrainTask: Task<Void, Never>?
    @ObservationIgnored private var didInstallTap = false

    init(configuration: AppConfiguration = .live) {
        tokenClient = LiveVoiceTokenClient(baseURL: configuration.apiBaseURL)
    }

    func start(language: AppLanguage, voice: String) async {
        guard connectionState == .idle || connectionState == .ended else { return }
        connectionState = .requestingPermission

        guard await requestMicrophonePermission() else {
            connectionState = .failed("voice_microphone_denied")
            return
        }

        do {
            connectionState = .connecting
            try configureAudioSession()

            let transport = GeminiLiveTransport { [weak self] event in
                self?.handle(event)
            }
            self.transport = transport
            let token = try await tokenClient.mint(voice: voice)
            try startAudioGraph(transport: transport)
            try await transport.connect(with: token, language: language)
        } catch {
            await stopAudioAndTransport()
            connectionState = .failed(Self.safeMessage(for: error))
        }
    }

    func toggleMute() {
        isMuted.toggle()
        let muted = isMuted
        Task { await transport?.setMuted(muted) }
    }

    func toggleSpeaker() {
        usesSpeaker.toggle()
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(
                usesSpeaker ? .speaker : .none
            )
        } catch {
            connectionState = .failed("voice_audio_route_failed")
        }
    }

    func end() async {
        await stopAudioAndTransport()
        connectionState = .ended
    }

    func handleInterruption() async {
        await end()
    }

    private func handle(_ event: GeminiLiveEvent) {
        switch event {
        case .connected(let model, let duration):
            speechSettleTask?.cancel()
            outputDrainTask?.cancel()
            speechSettleTask = nil
            outputDrainTask = nil
            modelName = model
            maximumDuration = duration
            startedAt = Date()
            connectionState = .connected
            phase = .listening
        case .interrupted:
            speechSettleTask?.cancel()
            outputDrainTask?.cancel()
            speechSettleTask = nil
            outputDrainTask = nil
            player.stop()
            phase = .listening
            audioLevel = 0
        case .audio(let data):
            speechSettleTask?.cancel()
            speechSettleTask = nil
            phase = .speaking
            schedulePlayback(data)
        case .ended:
            Task { await end() }
        case .failed(let message):
            connectionState = .failed(message)
            Task { await stopAudioAndTransport() }
        }
    }

    private func startAudioGraph(transport: GeminiLiveTransport) throws {
        let session = AVAudioSession.sharedInstance()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw APIError.invalidResponse
        }

        if !audioEngine.attachedNodes.contains(player) {
            audioEngine.attach(player)
        }
        let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: playbackFormat)

        let bufferSize = AVAudioFrameCount(max(1_024, inputFormat.sampleRate * 0.10))
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let packet = Self.makeInputPacket(from: buffer) else { return }
            Task { @concurrent in
                await transport.sendPCM16(packet.data)
                await self?.handleMicrophoneLevel(packet.level)
            }
        }
        didInstallTap = true
        audioEngine.prepare()
        try audioEngine.start()
        try session.overrideOutputAudioPort(usesSpeaker ? .speaker : .none)
    }

    private func schedulePlayback(_ data: Data) {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: 24_000,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channel = buffer.int16ChannelData?[0]
        else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.copyBytes(
            to: UnsafeMutableRawBufferPointer(
                start: channel,
                count: frameCount * MemoryLayout<Int16>.size
            )
        )

        let level = Self.pcmLevel(data)
        audioLevel = max(audioLevel * 0.45, level)
        player.scheduleBuffer(buffer)
        if !player.isPlaying {
            player.play()
        }

        outputDrainTask?.cancel()
        outputDrainTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, let self else { return }
            while self.player.isPlaying {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self.audioLevel *= 0.72
                if self.audioLevel < 0.035 { break }
            }
            self.audioLevel = 0
            if self.connectionState == .connected {
                self.phase = .listening
            }
        }
    }

    private func handleMicrophoneLevel(_ level: Double) {
        guard connectionState == .connected, phase != .speaking, !isMuted else { return }
        audioLevel = max(level, audioLevel * 0.68)
        guard level > 0.028 else { return }
        phase = .listening

        speechSettleTask?.cancel()
        speechSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(950))
            guard !Task.isCancelled, let self, self.connectionState == .connected else { return }
            self.audioLevel = 0.08
            self.phase = .thinking
        }
    }

    private func stopAudioAndTransport() async {
        speechSettleTask?.cancel()
        outputDrainTask?.cancel()
        speechSettleTask = nil
        outputDrainTask = nil
        if didInstallTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        player.stop()
        audioEngine.stop()
        await transport?.close()
        transport = nil
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    private nonisolated static func makeInputPacket(
        from buffer: AVAudioPCMBuffer
    ) -> (data: Data, level: Double)? {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.sampleRate > 0
        else { return nil }

        let source = channels[0]
        let sourceCount = Int(buffer.frameLength)
        let targetCount = max(
            1,
            Int(Double(sourceCount) * 16_000 / buffer.format.sampleRate)
        )
        let ratio = Double(sourceCount) / Double(targetCount)
        var pcm = [Int16](repeating: 0, count: targetCount)
        var energy = 0.0

        for targetIndex in 0 ..< targetCount {
            let position = Double(targetIndex) * ratio
            let lower = min(sourceCount - 1, Int(position))
            let upper = min(sourceCount - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            let sample = max(-1, min(1, source[lower] + (source[upper] - source[lower]) * fraction))
            energy += Double(sample * sample)
            pcm[targetIndex] = sample < 0
                ? Int16(sample * Float(Int16.min.magnitude))
                : Int16(sample * Float(Int16.max))
        }

        let data = pcm.withUnsafeBytes { Data($0) }
        return (data, sqrt(energy / Double(targetCount)))
    }

    private nonisolated static func pcmLevel(_ data: Data) -> Double {
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            guard !values.isEmpty else { return 0 }
            var sum = 0.0
            for index in stride(from: 0, to: values.count, by: 4) {
                let value = Double(Int16(littleEndian: values[index])) / Double(Int16.max)
                sum += value * value
            }
            return min(1, sqrt(sum / Double(max(1, values.count / 4))))
        }
    }

    private nonisolated static func safeMessage(for error: Error) -> String {
        if let apiError = error as? APIError,
           let message = apiError.errorDescription,
           message.hasPrefix("voice_") {
            return message
        }
        return "voice_connection_failed"
    }
}
