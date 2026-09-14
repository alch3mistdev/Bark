import Foundation
import AVFoundation
import BarkCore

/// `SpeechSynthesizing` over the ElevenLabs HTTP API (018, ADR-012). Opt-in
/// and off by default: selecting it transmits the reply text, which the
/// settings pane warns about explicitly. Nothing is persisted — the session is
/// ephemeral and the audio lives in memory for the duration of playback.
///
/// Unlike the system engine this one can fail (network, auth, credits), so it
/// reports failure to its caller instead of swallowing it. The
/// `SpeechSynthesizing` contract's "never throws" guarantee is satisfied one
/// level up by `FallbackSpeechSynthesizer`, which speaks the same text
/// on-device — Principle I's required failure direction, made structural.
public final class ElevenLabsSynthesizer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let baseURL: String
    private let config: CloudTTSConfigStore
    private let urlSession: URLSession
    private let deadline: Double

    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var pending: CheckedContinuation<Void, Never>?
    private var requestTask: Task<Data, Error>?
    private var stopEpoch = 0

    public init(config: CloudTTSConfigStore,
                baseURL: String = CloudTTSRequest.defaultBaseURL,
                urlSession: URLSession = ElevenLabsSynthesizer.makeSession(),
                deadline: Double = 10) {
        self.baseURL = baseURL
        self.config = config
        self.urlSession = urlSession
        self.deadline = deadline
        super.init()
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral   // no cache of reply content
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    /// Synthesize and play. Throws so the composite can fall back; a thrown
    /// error means nothing was played.
    public func synthesizeAndPlay(_ text: String) async throws {
        let bounded = CloudTTSRequest.boundedText(text)
        guard !bounded.isEmpty else { return }   // no request, no spend

        let data = try await fetchAudio(bounded)
        try await play(data)
    }

    func fetchAudio(_ text: String) async throws -> Data {
        let current = config.current
        // Not enabled, or no key: throw BEFORE touching the session, so the
        // system-voice backend provably makes no network request (SC-004).
        guard current.enabled, !current.apiKey.isEmpty else {
            throw SpeechSynthesisError.notConfigured
        }
        guard let url = CloudTTSRequest.synthesisURL(base: baseURL, voiceID: current.voiceID),
              let body = CloudTTSRequest.synthesisBody(text: text, modelID: current.modelID) else {
            throw SpeechSynthesisError.notConfigured
        }
        let key = current.apiKey
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let task = Task { [urlSession] () throws -> Data in
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch {
                throw SpeechSynthesisError.transport((error as NSError).localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw SpeechSynthesisError.badAudio("not an HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SpeechSynthesisError.http(http.statusCode)
            }
            guard !data.isEmpty else { throw SpeechSynthesisError.badAudio("empty body") }
            return data
        }
        setRequestTask(task)
        defer { setRequestTask(nil) }

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await task.value }
            group.addTask { [deadline] in
                try await Task.sleep(for: .seconds(deadline))
                throw SpeechSynthesisError.deadlineExceeded
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                task.cancel()
                return result
            } catch {
                group.cancelAll()
                task.cancel()
                throw error
            }
        }
    }

    /// Non-async so the lock is never held across a suspension point.
    private func setRequestTask(_ task: Task<Data, Error>?) {
        lock.lock()
        requestTask = task
        lock.unlock()
    }

    /// Fetch the account's voice list (explicit user action from Settings).
    /// Deliberately does NOT require `enabled` — the user fetches voices while
    /// setting the backend up, before switching to it.
    public func fetchVoices() async throws -> [ElevenLabsVoice] {
        let key = config.current.apiKey
        guard !key.isEmpty else { throw SpeechSynthesisError.notConfigured }
        guard let url = CloudTTSRequest.voicesURL(base: baseURL) else {
            throw SpeechSynthesisError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SpeechSynthesisError.transport((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SpeechSynthesisError.badAudio("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SpeechSynthesisError.http(http.statusCode)
        }
        return try CloudTTSRequest.decodeVoices(data)
    }

    private func play(_ data: Data) async throws {
        let audioPlayer: AVAudioPlayer
        do {
            audioPlayer = try AVAudioPlayer(data: data)
        } catch {
            throw SpeechSynthesisError.badAudio("undecodable audio")
        }
        audioPlayer.delegate = self
        guard audioPlayer.prepareToPlay() else {
            throw SpeechSynthesisError.badAudio("player refused the audio")
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            let epoch = stopEpoch
            player = audioPlayer
            pending = cont
            let stale = epoch != stopEpoch
            lock.unlock()
            // stop() landed while we were installing — don't start playing.
            if stale || !audioPlayer.play() {
                release()
            }
        }
    }

    /// Aborts the in-flight request and any playback; the pending `speak`
    /// (and thus the half-duplex gate) is released.
    public func stop() {
        lock.lock()
        stopEpoch += 1
        let task = requestTask
        let current = player
        lock.unlock()
        task?.cancel()
        current?.stop()
        release()
    }

    private func release() {
        lock.lock()
        let cont = pending
        pending = nil
        player = nil
        lock.unlock()
        cont?.resume()
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        release()
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        release()
    }
}
