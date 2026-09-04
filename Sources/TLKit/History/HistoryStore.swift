import Foundation

/// 翻译历史条目。
/// 加星标即「词典条目」：可生成详细解读（interpretation），随历史一同持久化。
struct HistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let sourceText: String
    /// 可写：详情页原地重翻后就地更新译文。
    var resultText: String
    let targetLang: String
    /// 可写：重翻可能换引擎，如实记录最后一次使用的引擎。
    var service: String
    /// 星标 = 收进词典。
    var isStarred: Bool
    /// 星标条目的详细解读（AI 引擎生成，nil = 尚未生成）。
    var interpretation: String?

    init(sourceText: String, resultText: String, targetLang: String, service: String) {
        self.id = UUID()
        self.date = Date()
        self.sourceText = sourceText
        self.resultText = resultText
        self.targetLang = targetLang
        self.service = service
        self.isStarred = false
        self.interpretation = nil
    }

    // 自定义解码：isStarred / interpretation 是后加字段，老 history.json 没有，
    // 缺字段时回退默认值而不是解析失败（与 ConfigStore 的升级策略一致）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        sourceText = try c.decode(String.self, forKey: .sourceText)
        resultText = try c.decode(String.self, forKey: .resultText)
        targetLang = try c.decode(String.self, forKey: .targetLang)
        service = try c.decode(String.self, forKey: .service)
        isStarred = try c.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        interpretation = try c.decodeIfPresent(String.self, forKey: .interpretation)
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
    /// 就地更新会换整条记录，星标与解读要保留——它们是用户手工标记的资产。
    func appendDedup(_ item: HistoryItem) {
        if let first = items.first,
           first.sourceText == item.sourceText,
           first.targetLang == item.targetLang,
           first.service == item.service {
            var updated = item
            updated.isStarred = first.isStarred
            updated.interpretation = first.interpretation
            items[0] = updated
            save()
            return
        }
        append(item)
    }

    /// 星标开关：星标条目即词典条目。
    func toggleStar(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isStarred.toggle()
        save()
    }

    /// 写入星标条目的详细解读。
    func setInterpretation(id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].interpretation = text
        save()
    }

    /// 原地重翻后就地更新译文与引擎，保留星标与解读（解读基于旧译文，交回用户重新生成）。
    func updateTranslation(id: UUID, resultText: String, service: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].resultText = resultText
        items[index].service = service
        save()
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

    // MARK: - 统计与导出

    /// 统计快照：全部从现有历史推导，不新增任何埋点（与隐私承诺一致）。
    struct Stats {
        var total: Int
        var today: Int
        var thisMonth: Int
        /// 引擎名 → 条数，按条数降序。
        var byService: [(name: String, count: Int)]
        /// 目标语言代码 → 条数，按条数降序。
        var byTargetLanguage: [(code: String, count: Int)]
        var starred: Int
    }

    var stats: Stats {
        let calendar = Calendar.current
        let now = Date()
        var byService: [String: Int] = [:]
        var byLang: [String: Int] = [:]
        var today = 0
        var thisMonth = 0
        var starred = 0
        for item in items {
            byService[item.service, default: 0] += 1
            byLang[item.targetLang, default: 0] += 1
            if calendar.isDateInToday(item.date) { today += 1 }
            if calendar.isDate(item.date, equalTo: now, toGranularity: .month) { thisMonth += 1 }
            if item.isStarred { starred += 1 }
        }
        return Stats(
            total: items.count,
            today: today,
            thisMonth: thisMonth,
            byService: byService.map { ($0.key, $0.value) }.sorted { $0.count > $1.count },
            byTargetLanguage: byLang.map { ($0.key, $0.value) }.sorted { $0.count > $1.count },
            starred: starred
        )
    }

    /// 导出 JSON（与落盘格式一致，美化输出）。
    func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(items)
    }

    /// 导出 CSV（带 UTF-8 BOM，Excel 直接打开不乱码）。
    func exportCSV() -> Data {
        let formatter = ISO8601DateFormatter()
        var lines = ["date,source,translation,target_language,service,starred"]
        for item in items {
            let row = [
                formatter.string(from: item.date),
                item.sourceText,
                item.resultText,
                item.targetLang,
                item.service,
                item.isStarred ? "1" : "0",
            ].map(Self.csvField).joined(separator: ",")
            lines.append(row)
        }
        let text = lines.joined(separator: "\r\n")
        // BOM + UTF-8：Excel 无 BOM 时按本地编码解析，中文必乱码。
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(text.data(using: .utf8) ?? Data())
        return data
    }

    /// CSV 字段转义：含逗号/引号/换行时加引号，引号自身翻倍。
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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

/// 原地重翻助手：历史窗口（详情按钮 / 右键菜单）共用。
/// 用当前激活引擎把同一条记录重翻一次并就地更新；返回错误文案（nil = 成功）。
@MainActor
enum HistoryRetranslator {
    @discardableResult
    static func run(_ item: HistoryItem) async -> String? {
        do {
            let service = try ServiceFactory.makeActive()
            let result = try await service.translate(item.sourceText, from: nil, to: item.targetLang)
            HistoryStore.shared.updateTranslation(id: item.id, resultText: result, service: service.displayName)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
