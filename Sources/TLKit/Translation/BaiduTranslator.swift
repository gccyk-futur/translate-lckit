import Foundation

/// 百度智能云机器翻译 API（texttrans/v1）。
/// 协议：OAuth 2.0 access token + JSON POST。
/// 文档：https://cloud.baidu.cn/doc/MT/s/4kqryjku9
struct BaiduTranslator: TranslationService {
    let apiKey: String
    let secretKey: String

    var displayName: String { "百度翻译" }

    func translate(_ text: String, to target: String) async throws -> String {
        let token = try await BaiduTokenStore.shared.getToken(apiKey: apiKey, secretKey: secretKey)

        guard let url = URL(string: "https://aip.baidubce.com/rpc/2.0/mt/texttrans/v1?access_token=\(Self.percentEncode(token))") else {
            throw TranslationError.network(message: "URL 无效")
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "q": text,
            "from": "auto",
            "to": target,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TranslationError.network(message: "请求超时")
        } catch {
            throw TranslationError.network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationError.network(message: "HTTP 状态码异常")
        }

        struct ResultItem: Decodable {
            let src: String?
            let dst: String
        }
        struct ResultPayload: Decodable {
            let trans_result: [ResultItem]?
        }
        struct Payload: Decodable {
            let error_code: Int?
            let error_msg: String?
            let result: ResultPayload?
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw TranslationError.server(message: "响应解析失败")
        }

        if let code = payload.error_code {
            throw TranslationError.server(message: payload.error_msg ?? "错误码 \(code)")
        }
        guard let items = payload.result?.trans_result, !items.isEmpty else {
            throw TranslationError.emptyResult
        }
        return items.map(\.dst).joined(separator: "\n")
    }

    // MARK: - 工具（internal 供单测验证）

    static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

/// 百度智能云 access token 缓存（actor 保证线程安全）。
/// Token 有效期 30 天，提前 5 分钟刷新。
private actor BaiduTokenStore {
    static let shared = BaiduTokenStore()

    private var token: String?
    private var expiry: Date?

    func getToken(apiKey: String, secretKey: String) async throws -> String {
        if let token, let expiry, expiry > Date() {
            return token
        }

        guard let url = URL(string: "https://aip.baidubce.com/oauth/2.0/token") else {
            throw TranslationError.network(message: "URL 无效")
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = "grant_type=client_credentials&client_id=\(BaiduTranslator.percentEncode(apiKey))&client_secret=\(BaiduTranslator.percentEncode(secretKey))"
        request.httpBody = params.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslationError.network(message: "获取 access_token 失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationError.network(message: "获取 access_token 失败：HTTP 状态码异常")
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
            let error: String?
            let error_description: String?
        }

        let tokenResp: TokenResponse
        do {
            tokenResp = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw TranslationError.server(message: "access_token 响应解析失败")
        }

        if let error = tokenResp.error {
            throw TranslationError.server(message: "获取 access_token 失败：\(error) \(tokenResp.error_description ?? "")")
        }

        // 缓存 token，提前 5 分钟过期。
        token = tokenResp.access_token
        expiry = Date().addingTimeInterval(TimeInterval(tokenResp.expires_in - 300))

        return tokenResp.access_token
    }
}
