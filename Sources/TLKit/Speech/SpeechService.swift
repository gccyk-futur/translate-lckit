import AVFoundation
import Foundation

/// TTS 统一协议：朗读指定语言的文本，await 直到播完或被打断。
@MainActor
protocol SpeechService {
    func speak(_ text: String, language: String) async throws
    func stop()
}

enum SpeechError: LocalizedError {
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        }
    }
}

/// 语言代码 → BCP-47（AVSpeechSynthesizer 需要完整 locale）。
func bcp47Language(from lang: String) -> String {
    switch lang.lowercased() {
    case "zh", "zh-cn": return "zh-CN"
    case "zh-tw", "yue": return "zh-TW"
    case "en": return "en-US"
    case "ja": return "ja-JP"
    case "ko": return "ko-KR"
    case "fra", "fr": return "fr-FR"
    case "de": return "de-DE"
    case "spa", "es": return "es-ES"
    case "ru": return "ru-RU"
    case "pt": return "pt-BR"
    case "it": return "it-IT"
    default: return lang
    }
}

/// 系统语音（AVSpeechSynthesizer）：免费、离线、免授权。
@MainActor
final class SystemSpeechService: NSObject, SpeechService, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    func speak(_ text: String, language: String) async throws {
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.delegate = self
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(for: language)
        // 朗读速度：用户倍率 0.5~2.0 → AVFoundation rate（默认 0.5 × 倍率，clamp 到合法范围）
        let multiplier = ConfigStore.shared.current.tts.speechRate
        let avRate = AVSpeechUtteranceDefaultSpeechRate * multiplier
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                             min(AVSpeechUtteranceMaximumSpeechRate, avRate))
        await withCheckedContinuation { cont in
            continuation = cont
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 优先设置里选定的声音；未选或语种与朗读文本不匹配时按语言自动选。
    static func resolveVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let configured = ConfigStore.shared.current.tts.systemVoice
        let target = bcp47Language(from: language)
        if !configured.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: configured),
           voice.language.hasPrefix(String(target.prefix(2))) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: target)
    }

    // MARK: - AVSpeechSynthesizerDelegate（播完/取消都要恢复 continuation）

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume()
    }

    nonisolated private func resume() {
        MainActor.assumeIsolated {
            let cont = continuation
            continuation = nil
            cont?.resume()
        }
    }
}

/// Azure Speech（微软神经语音）：走 REST，输出 mp3 用 AVAudioPlayer 播放。
@MainActor
final class AzureSpeechService: NSObject, SpeechService, AVAudioPlayerDelegate {
    let region: String
    let key: String
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?

    init(region: String, key: String) {
        self.region = region
        self.key = key
        super.init()
    }

    func speak(_ text: String, language: String) async throws {
        stop()
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            throw SpeechError.invalidConfiguration("Azure 区域配置无效")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-16khz-128kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        let rateMultiplier = ConfigStore.shared.current.tts.speechRate
        let ratePercent = Int((rateMultiplier - 1.0) * 100)
        request.httpBody = Self.ssml(text: text, voice: Self.resolveVoice(for: language), rate: ratePercent).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let player = try? AVAudioPlayer(data: data), player.prepareToPlay() else {
            throw SpeechError.invalidConfiguration("TTS 返回数据无法播放")
        }
        self.player = player
        player.delegate = self
        await withCheckedContinuation { cont in
            continuation = cont
            player.play()
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        resume()
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        resume()
    }

    nonisolated private func resume() {
        MainActor.assumeIsolated {
            let cont = continuation
            continuation = nil
            cont?.resume()
        }
    }

    /// 优先设置里选定的神经语音；未选或语种不匹配时按语言自动选。
    static func resolveVoice(for language: String) -> String {
        let configured = ConfigStore.shared.current.tts.azureVoice
        let prefix = String(language.lowercased().prefix(2))
        if !configured.isEmpty, configured.lowercased().hasPrefix(prefix) {
            return configured
        }
        return voice(for: language)
    }

    /// 按目标语言挑选神经语音（默认女声）。
    static func voice(for lang: String) -> String {
        switch lang.lowercased() {
        case "zh": return "zh-CN-XiaoxiaoNeural"
        case "en": return "en-US-AriaNeural"
        case "ja": return "ja-JP-NanamiNeural"
        case "ko": return "ko-KR-SunHiNeural"
        case "fra", "fr": return "fr-FR-DeniseNeural"
        case "de": return "de-DE-KatjaNeural"
        case "spa", "es": return "es-ES-ElviraNeural"
        case "ru": return "ru-RU-SvetlanaNeural"
        case "pt": return "pt-BR-FranciscaNeural"
        case "it": return "it-IT-ElsaNeural"
        default: return "en-US-AriaNeural"
        }
    }

    static func ssml(text: String, voice: String, rate: Int = 0) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US">
          <voice name="\(voice)">
            <prosody rate="\(rate)%">\(escaped)</prosody>
          </voice>
        </speak>
        """
    }
}

/// TTS 调度：按设置挑选服务，支持播放中再次点击停止。
@MainActor
final class SpeechManager {
    static let shared = SpeechManager()

    private var service: SpeechService?
    private var task: Task<Void, Never>?
    private(set) var isSpeaking = false

    private init() {}

    /// 开始朗读；若正在朗读同一来源则停止（切换式交互）。
    func toggle(text: String, language: String) {
        if isSpeaking {
            stop()
            return
        }
        let service = Self.resolveService()
        self.service = service
        isSpeaking = true
        task = Task {
            do {
                try await service.speak(text, language: language)
            } catch {
                print("[TLKit] TTS 失败：\(error.localizedDescription)")
            }
            if !Task.isCancelled {
                isSpeaking = false
            }
        }
    }

    func stop() {
        service?.stop()
        task?.cancel()
        task = nil
        service = nil
        isSpeaking = false
    }

    /// 按当前设置构造语音服务；Azure 未配置时自动回退系统语音。
    static func resolveService() -> SpeechService {
        let tts = ConfigStore.shared.current.tts
        switch tts.provider {
        case .azure:
            let key = (KeychainStore.get(.azureKey) ?? "").trimmingCharacters(in: .whitespaces)
            let region = tts.azureRegion.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !region.isEmpty else {
                return SystemSpeechService()
            }
            return AzureSpeechService(region: region, key: key)
        case .system:
            return SystemSpeechService()
        }
    }
}
