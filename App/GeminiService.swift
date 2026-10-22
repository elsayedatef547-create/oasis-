import Foundation
import UIKit

// MARK: - Errors

enum GeminiError: LocalizedError {
    case missingAPIKey
    case invalidModel
    case network(String)
    case http(Int, String)
    case blocked(String)
    case emptyResponse
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "لم يتم إدخال مفتاح Gemini API. أضفه من تبويب الإعدادات."
        case .invalidModel:
            return "اسم النموذج غير صالح. تحقق من الإعدادات."
        case .network(let message):
            return "تعذّر الاتصال بالخادم: \(message)"
        case .http(let code, let message):
            return "خطأ من الخادم (\(code)): \(message)"
        case .blocked(let reason):
            return "تم حظر الطلب من قبل Gemini: \(reason)"
        case .emptyResponse:
            return "لم يُرجع Gemini أي نتيجة."
        case .parsing(let message):
            return "تعذّر قراءة نتيجة Gemini: \(message)"
        }
    }
}

// MARK: - Extracted item

struct ExtractedItem: Decodable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var code: String
    var qty: Double
    var unitPrice: Double
    var total: Double

    enum CodingKeys: String, CodingKey {
        case name
        case code
        case qty
        case unitPrice = "unit_price"
        case total
    }

    init(name: String, code: String, qty: Double, unitPrice: Double, total: Double) {
        self.name = name
        self.code = code
        self.qty = qty
        self.unitPrice = unitPrice
        self.total = total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = container.lenientString(.name)
        let decodedCode = container.lenientString(.code).normalizedDigits.trimmed
        var decodedQty = container.lenientDouble(.qty)
        var decodedPrice = container.lenientDouble(.unitPrice)
        var decodedTotal = container.lenientDouble(.total)

        if decodedQty <= 0 && (decodedPrice > 0 || decodedTotal > 0) {
            decodedQty = 1
        }
        if decodedTotal <= 0 && decodedQty > 0 && decodedPrice > 0 {
            decodedTotal = decodedQty * decodedPrice
        }
        if decodedPrice <= 0 && decodedQty > 0 && decodedTotal > 0 {
            decodedPrice = decodedTotal / decodedQty
        }

        self.name = decodedName
        self.code = decodedCode
        self.qty = decodedQty
        self.unitPrice = decodedPrice
        self.total = decodedTotal
    }
}

/// الفاتورة المستخرجة: بيانات الرأس + الأصناف
struct ExtractedInvoice {
    var supplier: String = ""
    var invoiceNumber: String = ""
    var date: Date?
    var items: [ExtractedItem] = []
}

private struct ExtractedHeader: Decodable {
    var supplier = ""
    var invoiceNumber = ""
    var date = ""

    enum CodingKeys: String, CodingKey {
        case supplier
        case invoiceNumber = "invoice_number"
        case date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supplier = container.lenientString(.supplier)
        invoiceNumber = container.lenientString(.invoiceNumber)
        date = container.lenientString(.date)
    }
}

private extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = try? decode(Double.self, forKey: key) {
            if abs(number) < 1e15 && number == number.rounded() {
                return String(Int64(number))
            }
            return String(number)
        }
        return ""
    }

    func lenientDouble(_ key: Key) -> Double {
        if let number = try? decode(Double.self, forKey: key) {
            return number
        }
        if let text = try? decode(String.self, forKey: key) {
            return text.parsedDouble ?? 0
        }
        return 0
    }
}

// MARK: - Request / response payloads

private struct GeminiRequest: Encodable {
    struct InlineData: Encodable {
        let mimeType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    struct Part: Encodable {
        let text: String?
        let inlineData: InlineData?

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }
    }

    struct Content: Encodable {
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let responseMimeType: String

        enum CodingKeys: String, CodingKey {
            case temperature
            case responseMimeType = "response_mime_type"
        }
    }

    let contents: [Content]
    let generationConfig: GenerationConfig

    enum CodingKeys: String, CodingKey {
        case contents
        case generationConfig = "generation_config"
    }
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }

    struct Content: Decodable {
        let parts: [Part]?
    }

    struct Part: Decodable {
        let text: String?
    }

    struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}

private struct GeminiErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: Int?
        let message: String?
    }

    let error: Detail?
}

// MARK: - Service

private struct HTTPFailure: Error {
    let status: Int
    let message: String
    let raw: String
}

enum GeminiService {
    /// نفس برومبت نسخة الويب: يحدد اللغة، يفهم أسماء الأعمدة، ويتجاهل عمود الترقيم.
    static func buildPrompt(language: InvoiceLanguage, precise: Bool) -> String {
        var lines: [String] = [
            "You are an OCR and document-parsing engine. The attached image(s) are the pages of ONE document, in order. It may be an invoice, a delivery note, an order, a packing list or a stock list: any document that lists products in rows.",
            "Invoice language: \(language.promptName)." + (precise ? " The text may be handwritten or low quality: read every line carefully." : ""),
            "If any numbers are written with Arabic-Indic digits, convert them to Western digits (0-9).",
            "Reply with only one JSON object of this exact shape:",
            "{\"supplier\": string|null, \"invoice_number\": string|null, \"date\": string|null, \"currency\": string|null, \"items\": [{\"name\": string, \"code\": string|null, \"qty\": number, \"unit\": string|null, \"unit_price\": number|null, \"total\": number|null}]}",
            "Rules:",
            "- One entry per product line, in printed order, across all pages. Keep duplicate products as separate entries.",
            "- Column names vary: the product name may be headed Artículo, Producto, Descripción, Name or Item; the code may be headed REF, Referencia, Código, SKU or Ref; the quantity may be headed Cantidad, Uds, Unidades, Qty, Quantity or Stock. Use them as name, code and qty.",
            "- Ignore a plain row-number column (such as Nº, #, Línea). Never use it as the code or the quantity.",
            "- The document may have no prices or totals: then unit_price and total are null. Never skip a product only because prices are missing.",
            "- Copy names and codes exactly as printed. Do not translate them.",
            "- qty, unit_price and total are plain numbers with a dot for decimals. unit is the printed unit such as kg, L, ud, caja, or null.",
            "- Skip subtotal, tax (IVA), discount, shipping and payment lines.",
            "- Use null for any value that is illegible. If a line clearly shows a single unit with no number, qty is 1.",
            "- Only if there is no table or list of products at all, reply {\"items\": []}."
        ]
        if language == .arabic {
            lines.append("- Keep Arabic product names as Arabic text.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Image preparation

    static func prepareImage(_ image: UIImage, maxDimension: CGFloat = 2000, quality: CGFloat = 0.8) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = min(1, maxDimension / longest)
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    // MARK: Extraction

    static func extractInvoice(from data: Data, mimeType: String) async throws -> ExtractedInvoice {
        guard let storedKey = KeychainHelper.readAPIKey(), !storedKey.trimmed.isEmpty else {
            throw GeminiError.missingAPIKey
        }
        let apiKey = storedKey.trimmed
        let defaults = UserDefaults.standard

        let precise = defaults.object(forKey: AppSettings.preciseKey) as? Bool ?? true
        let language = InvoiceLanguage(rawValue: defaults.string(forKey: AppSettings.languageKey) ?? "") ?? .both

        var userModel = (defaults.string(forKey: AppSettings.modelKey) ?? AppSettings.defaultModel).trimmed
        if userModel.isEmpty { userModel = AppSettings.defaultModel }
        if userModel.hasPrefix("models/") { userModel = String(userModel.dropFirst("models/".count)) }

        // دقة أعلى = الموديل اللي اخترته. غير كده = الموديل الخفيف.
        let model = precise ? userModel : AppSettings.liteModel
        let prompt = buildPrompt(language: language, precise: precise)

        let text = try await generate(
            prompt: prompt, data: data, mimeType: mimeType,
            apiKey: apiKey, model: model, forced: false, attempt: 0
        )
        return try parseInvoice(from: text)
    }

    /// تاريخ الفاتورة من نص (الإسباني: يوم/شهر/سنة أولًا). nil لو مش مفهوم.
    /// طلب نصي بس (من غير صورة) — بنستخدمه لمطابقة الأسماء.
    static func askText(_ prompt: String) async throws -> String {
        guard let storedKey = KeychainHelper.readAPIKey(), !storedKey.trimmed.isEmpty else {
            throw GeminiError.missingAPIKey
        }
        let defaults = UserDefaults.standard
        var model = (defaults.string(forKey: AppSettings.modelKey) ?? AppSettings.defaultModel).trimmed
        if model.isEmpty { model = AppSettings.defaultModel }
        if model.hasPrefix("models/") { model = String(model.dropFirst("models/".count)) }
        return try await send(prompt: prompt, data: nil, mimeType: nil, apiKey: storedKey.trimmed, model: model)
    }

    static func parseDate(_ raw: String) -> Date? {
        let text = raw.normalizedDigits.trimmed
        if text.isEmpty { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "dd/MM/yyyy", "d/M/yyyy", "dd-MM-yyyy", "dd.MM.yyyy", "yyyy/MM/dd", "dd/MM/yy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// يطلب من Gemini مع: تبديل الموديل لو 404، وتبديل/انتظار وإعادة محاولة لو 429.
    private static func generate(
        prompt: String, data: Data, mimeType: String,
        apiKey: String, model: String, forced: Bool, attempt: Int
    ) async throws -> String {
        do {
            return try await send(prompt: prompt, data: data, mimeType: mimeType, apiKey: apiKey, model: model)
        } catch let failure as HTTPFailure {
            let alt = [AppSettings.defaultModel, AppSettings.liteModel].first { $0 != model }

            if failure.status == 404 && !forced, let alt {
                return try await generate(
                    prompt: prompt, data: data, mimeType: mimeType,
                    apiKey: apiKey, model: alt, forced: true, attempt: attempt
                )
            }

            if failure.status == 429 {
                let daily = failure.raw.range(of: "PerDay", options: .caseInsensitive) != nil
                    || failure.raw.range(of: "per day", options: .caseInsensitive) != nil
                let delay = retryDelay(in: failure.raw) ?? 12
                let error = GeminiError.http(429, failure.message)

                if forced { throw error }

                if let alt {
                    do {
                        return try await generate(
                            prompt: prompt, data: data, mimeType: mimeType,
                            apiKey: apiKey, model: alt, forced: true, attempt: attempt
                        )
                    } catch GeminiError.http(429, _) {
                        if daily { throw error }
                    }
                }

                if !daily && delay <= 45 && attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    return try await generate(
                        prompt: prompt, data: data, mimeType: mimeType,
                        apiKey: apiKey, model: model, forced: false, attempt: attempt + 1
                    )
                }
                throw error
            }

            throw GeminiError.http(failure.status, failure.message)
        }
    }

    private static func retryDelay(in raw: String) -> Int? {
        let patterns = [#"retryDelay\W+([\d.]+)s"#, #"retry in ([\d.]+)s"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: raw),
                  let seconds = Double(raw[range]) else { continue }
            return Int(seconds.rounded(.up)) + 1
        }
        return nil
    }

    static func send(
        prompt: String, data: Data?, mimeType: String?, apiKey: String, model: String
    ) async throws -> String {
        guard
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")
        else {
            throw GeminiError.invalidModel
        }

        var parts = [GeminiRequest.Part(text: prompt, inlineData: nil)]
        if let data, let mimeType {
            parts.append(
                GeminiRequest.Part(
                    text: nil,
                    inlineData: GeminiRequest.InlineData(mimeType: mimeType, data: data.base64EncodedString())
                )
            )
        }
        let body = GeminiRequest(
            contents: [GeminiRequest.Content(parts: parts)],
            generationConfig: GeminiRequest.GenerationConfig(
                temperature: 0.1,
                responseMimeType: "application/json"
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw GeminiError.network(error.localizedDescription)
        }

        guard let http = result.1 as? HTTPURLResponse else {
            throw GeminiError.emptyResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: result.0)
            let raw = String(data: result.0, encoding: .utf8) ?? ""
            throw HTTPFailure(status: http.statusCode, message: envelope?.error?.message ?? raw, raw: raw)
        }

        let decoded: GeminiResponse
        do {
            decoded = try JSONDecoder().decode(GeminiResponse.self, from: result.0)
        } catch {
            throw GeminiError.parsing(error.localizedDescription)
        }

        if let reason = decoded.promptFeedback?.blockReason, !reason.isEmpty {
            throw GeminiError.blocked(reason)
        }

        let text = (decoded.candidates?.first?.content?.parts ?? [])
            .compactMap { $0.text }
            .joined()

        if text.trimmed.isEmpty {
            throw GeminiError.emptyResponse
        }
        return text
    }

    // MARK: Parsing

    /// يقبل كائن {"items": [...]} (الشكل الجديد) أو مصفوفة مباشرة (احتياطًا).
    static func parseInvoice(from text: String) throws -> ExtractedInvoice {
        var cleaned = text.trimmed
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmed
        }

        var jsonData: Data?
        var useWrapper = false

        let firstBrace = cleaned.firstIndex(of: "{")
        let lastBrace = cleaned.lastIndex(of: "}")
        let firstBracket = cleaned.firstIndex(of: "[")
        let lastBracket = cleaned.lastIndex(of: "]")

        if let fb = firstBrace, let lb = lastBrace, fb < lb, (firstBracket.map { fb < $0 } ?? true) {
            jsonData = String(cleaned[fb...lb]).data(using: .utf8)
            useWrapper = true
        } else if let fk = firstBracket, let lk = lastBracket, fk < lk {
            jsonData = String(cleaned[fk...lk]).data(using: .utf8)
        }

        guard let jsonData else {
            throw GeminiError.parsing("لم يتم العثور على JSON في الرد.")
        }

        do {
            var result = ExtractedInvoice()
            let items: [ExtractedItem]
            if useWrapper {
                struct Wrapper: Decodable { let items: [ExtractedItem]? }
                items = try JSONDecoder().decode(Wrapper.self, from: jsonData).items ?? []
                if let header = try? JSONDecoder().decode(ExtractedHeader.self, from: jsonData) {
                    result.supplier = header.supplier.trimmed
                    result.invoiceNumber = header.invoiceNumber.trimmed
                    result.date = parseDate(header.date)
                }
            } else {
                items = try JSONDecoder().decode([ExtractedItem].self, from: jsonData)
            }
            result.items = items.filter { item in
                !(item.name.trimmed.isEmpty && item.code.trimmed.isEmpty && item.total == 0)
            }
            return result
        } catch {
            throw GeminiError.parsing(error.localizedDescription)
        }
    }
}
