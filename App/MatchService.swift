import SwiftUI
import SwiftData

// MARK: - Name tokens

enum NameTokens {
    /// كلمات عامة مش بتفرّق بين صنفين
    static let generic: Set<String> = ["perfume", "parfum", "spray", "eau", "de", "the"]

    static func tokens(_ raw: String) -> [String] {
        var text = raw.normalizedDigits.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        text = text.replacingOccurrences(of: "([0-9])([a-z])", with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(of: "([a-z])([0-9])", with: "$1 $2", options: .regularExpression)
        return text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func core(_ raw: String) -> [String] {
        tokens(raw).filter { !generic.contains($0) }
    }

    /// مفتاح الاسم من غير ترتيب الكلمات ولا علامات الترقيم
    static func key(_ raw: String) -> String {
        core(raw).sorted().joined(separator: " ")
    }

    static func hasDigit(_ token: String) -> Bool {
        token.contains { $0.isNumber }
    }

    static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !hasDigit(a), !hasDigit(b), min(a.count, b.count) >= 5 else { return false }
        return distance(Array(a), Array(b)) <= 1
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if abs(a.count - b.count) > 1 { return 2 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }

    /// تشابه (Dice) بين اسمين، بيسمح بغلطة حرف واحدة في الكلمات الطويلة
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var used = Set<Int>()
        var matched = 0
        for token in a {
            if let idx = b.indices.first(where: { !used.contains($0) && fuzzyEqual(token, b[$0]) }) {
                used.insert(idx)
                matched += 1
            }
        }
        return 2 * Double(matched) / Double(a.count + b.count)
    }

    /// نفس الكلمات تمامًا (مع تسامح في الإملاء) وأرقام/أحجام متطابقة
    static func sameProduct(_ a: [String], _ b: [String]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        let digitsA = Set(a.filter(hasDigit)), digitsB = Set(b.filter(hasDigit))
        guard digitsA == digitsB else { return false }
        return similarity(a, b) == 1
    }
}

// MARK: - Match service

struct MatchOutcome {
    var auto = 0
    var suggested = 0
    var aiError: String?
}

@MainActor
enum MatchService {
    private struct Pending {
        let item: InvoiceItem
        let candidates: [(product: Product, score: Double)]
    }

    private struct AIResponse: Decodable {
        struct Result: Decodable {
            let item: Int
            let candidate: Int?
            let confidence: Double?
        }
        let results: [Result]
    }

    /// بيطابق أصناف الفاتورة اللي مش موجودة في الشيت بالاسم.
    /// تلقائي بس لو الاسم نفسه فعلًا. أي اختلاف في كلمة مميزة (لون/حجم/نسخة) بيتحوّل لاقتراح محتاج تأكيد.
    static func resolve(invoice: Invoice, in context: ModelContext, useAI: Bool = true) async -> MatchOutcome {
        var outcome = MatchOutcome()
        let products = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        let aliases = (try? context.fetch(FetchDescriptor<ProductAlias>())) ?? []
        guard !products.isEmpty else { return outcome }

        let index = ProductIndex(products: products)
        let productTokens = products.map { NameTokens.core($0.name) }
        var pending: [Pending] = []

        for item in invoice.items where !item.prepared && !item.name.trimmed.isEmpty {
            if index.product(matchKey: item.matchedKey) != nil { continue }
            if index.find(sku: "", code: item.code, name: item.name) != nil { continue }

            let nameKey = NameTokens.key(item.name)
            let tokens = NameTokens.core(item.name)

            // 1) حاجة المستخدم أكدها قبل كده
            if let alias = aliases.first(where: { $0.nameKey == nameKey }),
               index.product(matchKey: alias.productKey) != nil {
                item.matchedKey = alias.productKey
                item.suggestedKey = ""
                item.matchAuto = true
                outcome.auto += 1
                continue
            }

            // 2) نفس الاسم بعد تنضيف الترتيب والترقيم
            if let same = zip(products, productTokens).first(where: { NameTokens.sameProduct(tokens, $0.1) })?.0,
               !same.matchKey.isEmpty {
                item.matchedKey = same.matchKey
                item.suggestedKey = ""
                item.matchAuto = true
                outcome.auto += 1
                continue
            }

            // 3) مرشحين بالتشابه
            let ranked = zip(products, productTokens)
                .map { (product: $0.0, score: NameTokens.similarity(tokens, $0.1)) }
                .filter { $0.score > 0 && !$0.product.matchKey.isEmpty }
                .sorted { $0.score > $1.score }
                .prefix(8)
            pending.append(Pending(item: item, candidates: Array(ranked)))
        }

        // Gemini يختار من المرشحين بس (مبيخترعش أسماء)
        var aiPicks: [Int: (candidate: Int, confidence: Double)] = [:]
        let askable = pending.enumerated().filter { !$0.element.candidates.isEmpty }
        if useAI, !askable.isEmpty, KeychainHelper.readAPIKey()?.trimmed.isEmpty == false {
            do {
                aiPicks = try await askGemini(askable.map { ($0.offset, $0.element) })
            } catch {
                outcome.aiError = error.localizedDescription
            }
        }

        for (offset, entry) in pending.enumerated() {
            let item = entry.item
            let tokens = NameTokens.core(item.name)
            var chosen: Product?
            var autoOK = false

            if let pick = aiPicks[offset], pick.candidate >= 1, pick.candidate <= entry.candidates.count, pick.confidence >= 0.5 {
                let product = entry.candidates[pick.candidate - 1].product
                chosen = product
                autoOK = pick.confidence >= 0.9 && NameTokens.sameProduct(tokens, NameTokens.core(product.name))
            } else if let best = entry.candidates.first, best.score >= 0.5 {
                chosen = best.product
            }

            guard let product = chosen else { continue }
            if autoOK {
                item.matchedKey = product.matchKey
                item.suggestedKey = ""
                item.matchAuto = true
                outcome.auto += 1
            } else if product.matchKey != item.rejectedKey {
                item.suggestedKey = product.matchKey
                outcome.suggested += 1
            }
        }

        try? context.save()
        return outcome
    }

    static func accept(_ item: InvoiceItem, product: Product, in context: ModelContext) {
        item.matchedKey = product.matchKey
        item.suggestedKey = ""
        item.matchAuto = false
        let nameKey = NameTokens.key(item.name)
        if !nameKey.isEmpty {
            let aliases = (try? context.fetch(FetchDescriptor<ProductAlias>())) ?? []
            if let existing = aliases.first(where: { $0.nameKey == nameKey }) {
                existing.productKey = product.matchKey
            } else {
                context.insert(ProductAlias(nameKey: nameKey, productKey: product.matchKey))
            }
        }
        try? context.save()
    }

    static func reject(_ item: InvoiceItem, in context: ModelContext) {
        item.rejectedKey = item.suggestedKey
        item.suggestedKey = ""
        try? context.save()
    }

    // MARK: Gemini

    private static func askGemini(_ batch: [(Int, Pending)]) async throws -> [Int: (candidate: Int, confidence: Double)] {
        var lines: [String] = []
        for (number, (_, entry)) in batch.enumerated() {
            lines.append("\(number + 1). \"\(entry.item.name)\"")
            let options = entry.candidates.enumerated()
                .map { "   \($0.offset + 1)) \"\($0.element.product.name)\"" }
                .joined(separator: "\n")
            lines.append("   candidates:\n\(options)")
        }

        let prompt = """
        You match product names from a supplier invoice to products in a store catalog (names may be Arabic or English).
        For each invoice item you get numbered candidates from the catalog. Choose the candidate that is the SAME product, or null.

        Rules:
        - A different color, size/volume (ml), scent name, edition or variant word means a DIFFERENT product. Example: "Fakhar Silver" and "Fakhar Black" are different products.
        - You may ignore only: word order, casing, punctuation, spelling/transliteration variants of the same word, Arabic vs English writing of the same name, and generic words (perfume, spray).
        - If you are not sure, answer null. Never invent a candidate number.

        Return ONLY JSON: {"results":[{"item":<item number>,"candidate":<candidate number or null>,"confidence":<0 to 1>}]}

        Items:
        \(lines.joined(separator: "\n"))
        """

        let text = try await GeminiService.askText(prompt)
        var cleaned = text.trimmed
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmed
        }
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AIResponse.self, from: data) else {
            return [:]
        }

        var picks: [Int: (candidate: Int, confidence: Double)] = [:]
        for result in decoded.results {
            guard result.item >= 1, result.item <= batch.count, let candidate = result.candidate else { continue }
            picks[batch[result.item - 1].0] = (candidate, result.confidence ?? 0)
        }
        return picks
    }
}

// MARK: - UI

/// اقتراح مطابقة محتاج تأكيد
struct MatchSuggestionRow: View {
    let item: InvoiceItem
    let product: Product
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("في الفاتورة: \(item.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("هل تقصد: \(product.name)؟")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Button(action: onAccept) {
                    Label("أيوه، نفس الصنف", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: onReject) {
                    Label("لا", systemImage: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
