import Foundation

/// 翻译历史条目。
struct HistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let sourceText: String
    let resultText: String
    let targetLang: String
    let service: String

    init(sourceText: String, resultText: String, targetLang: String, service: String) {
        self.id = UUID()
        self.date = Date()
        self.sourceText = sourceText
        self.resultText = resultText
        self.targetLang = targetLang
        self.service = service
    }
}

/// 本地历史存储：JSON 落盘（Application Support/TLKit/history.json），
/// 容量上限可配置，超出滚动淘汰最旧记录。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var items: [HistoryItem] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TLKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func append(_ item: HistoryItem) {
        items.insert(item, at: 0)
        items = Self.trimmed(items, maxCount: ConfigStore.shared.current.historyMaxCount)
        save()
    }

    /// 去重追加：最新一条若同原文、同方向、同服务，则就地更新而非新增。
    /// 输入面板实时翻译时避免每次停顿都刷屏一条历史。
    func appendDedup(_ item: HistoryItem) {
        if let first = items.first,
           first.sourceText == item.sourceText,
           first.targetLang == item.targetLang,
           first.service == item.service {
            items[0] = item
            save()
            return
        }
        append(item)
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// 历史保留条数设置变更后重新裁剪。
    func applyLimit() {
        items = Self.trimmed(items, maxCount: ConfigStore.shared.current.historyMaxCount)
        save()
    }

    /// 滚动淘汰：只保留最新的 maxCount 条（纯函数，可单测）。
    static func trimmed(_ items: [HistoryItem], maxCount: Int) -> [HistoryItem] {
        guard maxCount > 0, items.count > maxCount else { return items }
        return Array(items.prefix(maxCount))
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
