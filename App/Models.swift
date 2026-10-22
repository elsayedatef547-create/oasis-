import Foundation
import SwiftData
import SwiftUI

// MARK: - Settings keys

enum AppSettings {
    static let modelKey = "gemini_model"
    static let sheetsURLKey = "google_sheets_url"
    static let defaultModel = "gemini-3.8-flash"
    /// موديل خفيف وسريع يُستخدم لما تكون «القراءة بدقة أعلى» مقفولة (زي نسخة الويب).
    static let liteModel = "gemini-3.5-flash-lite"
    static let languageKey = "invoice_language"
    static let preciseKey = "invoice_precise"
    static let modelMigrationKey = "gemini_model_migrated_3_8"
    static let modelPresets: [String] = [
        "gemini-3.8-flash",
        "gemini-3.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-2.5-pro"
    ]

    /// One-time migration: apps that saved an older model name switch to the new default.
    static func migrateModelIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: modelMigrationKey) else { return }
        defaults.set(defaultModel, forKey: modelKey)
        defaults.set(true, forKey: modelMigrationKey)
    }
}

/// لغة الفاتورة المتوقعة (تُرسل في البرومبت لتحسين القراءة).
enum InvoiceLanguage: String, CaseIterable, Identifiable {
    case both = "esen"
    case spanish = "es"
    case english = "en"
    case arabic = "ar"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "الإسبانية + الإنجليزية"
        case .spanish: return "الإسبانية"
        case .english: return "الإنجليزية"
        case .arabic: return "العربية"
        }
    }

    var promptName: String {
        switch self {
        case .both: return "Spanish and English (mixed)"
        case .spanish: return "Spanish"
        case .english: return "English"
        case .arabic: return "Arabic"
        }
    }
}

// MARK: - SwiftData Models

@Model
final class Invoice {
    var title: String
    var supplier: String
    var date: Date
    var totalAmount: Double
    var notes: String
    /// "new" | "preparing" | "done"
    var status: String = "new"
    /// اتضافت أصناف الفاتورة للمخزون قبل كده؟ (لمنع تكرار الإضافة)
    var addedToInventory: Bool = false
    /// "sale" (فاتورة بيع/طلب يتجهّز ويخصم من المخزون) | "supply" (فاتورة توريد تزوّد المخزون)
    var kind: String = "sale"
    @Attribute(.externalStorage) var imageData: Data?

    @Relationship(deleteRule: .cascade, inverse: \InvoiceItem.invoice)
    var items: [InvoiceItem] = []

    init(
        title: String,
        supplier: String = "",
        date: Date = Date(),
        totalAmount: Double = 0,
        notes: String = "",
        imageData: Data? = nil
    ) {
        self.title = title
        self.supplier = supplier
        self.date = date
        self.totalAmount = totalAmount
        self.notes = notes
        self.imageData = imageData
    }

    func recalculateTotal() {
        totalAmount = items.reduce(0) { $0 + $1.total }
    }
}

@Model
final class InvoiceItem {
    var name: String
    var code: String
    var qty: Double
    var unitPrice: Double
    var total: Double
    var sortIndex: Int
    var prepared: Bool = false
    /// الكمية اللي اتخصمت فعلًا من المخزون لما اتعلّم الصنف «جُهّز» (عشان نرجّعها لو اتلغى)
    var stockDeducted: Double = 0
    /// مفتاح الصنف في المخزون اللي اتطابق معاه الصنف ده (SKU أو الكود) لما الاسم يختلف عن الشيت
    var matchedKey: String = ""
    /// اقتراح محتاج تأكيد من المستخدم ("هل تقصد ...؟")
    var suggestedKey: String = ""
    /// اقتراح المستخدم رفضه، منقترحوش تاني
    var rejectedKey: String = ""
    /// المطابقة اتعملت تلقائيًا (مش بتأكيد يدوي)
    var matchAuto: Bool = false
    var invoice: Invoice?

    init(
        name: String,
        code: String = "",
        qty: Double = 1,
        unitPrice: Double = 0,
        total: Double = 0,
        sortIndex: Int = 0
    ) {
        self.name = name
        self.code = code
        self.qty = qty
        self.unitPrice = unitPrice
        self.total = total
        self.sortIndex = sortIndex
    }
}

/// ذاكرة المطابقة: اسم الصنف في الفاتورة (منظّف) ← صنف في الشيت. بتتحفظ لما المستخدم يؤكد.
@Model
final class ProductAlias {
    var nameKey: String = ""
    var productKey: String = ""

    init(nameKey: String, productKey: String) {
        self.nameKey = nameKey
        self.productKey = productKey
    }
}

@Model
final class Product {
    var name: String
    var code: String
    var qty: Double
    var price: Double
    var sku: String = ""
    var cost: Double = 0
    var imageURL: String = ""
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        code: String = "",
        qty: Double = 0,
        price: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.code = code
        self.qty = qty
        self.price = price
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Inventory merge service

struct InventoryEntry {
    var name: String
    var code: String
    var qty: Double
    var price: Double      // سعر البيع
    var cost: Double = 0   // سعر الشراء / التكلفة
    var sku: String = ""
    /// false لو خانة الكمية في الملف فاضية أو نص (زي "Sin dato") فمنلمسش كمية المنتج
    var hasQty: Bool = true
}

enum InventoryMergeMode {
    case addQuantity
    case replaceQuantity
}

struct InventoryMergeResult {
    var added: Int = 0
    var updated: Int = 0
}

enum InventoryService {
    @discardableResult
    static func merge(
        _ entries: [InventoryEntry],
        mode: InventoryMergeMode,
        in context: ModelContext
    ) -> InventoryMergeResult {
        let existing = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        var index = ProductIndex(products: existing)

        var result = InventoryMergeResult()

        for entry in entries {
            let name = entry.name.trimmed
            let code = entry.code.trimmed
            if name.isEmpty && code.isEmpty && entry.sku.trimmed.isEmpty { continue }

            let match = index.find(sku: entry.sku, code: code, name: name)

            if let product = match {
                switch mode {
                case .addQuantity:
                    product.qty += entry.qty
                case .replaceQuantity:
                    if entry.hasQty { product.qty = entry.qty }
                }
                if entry.price > 0 {
                    product.price = entry.price
                }
                if entry.cost > 0 {
                    product.cost = entry.cost
                }
                if !name.isEmpty {
                    product.name = name
                }
                if product.code.trimmed.isEmpty && !code.isEmpty {
                    product.code = code
                }
                if product.sku.trimmed.isEmpty && !entry.sku.trimmed.isEmpty {
                    product.sku = entry.sku.trimmed
                }
                product.updatedAt = Date()
                index.add(product)
                result.updated += 1
            } else {
                let product = Product(
                    name: name.isEmpty ? (code.isEmpty ? entry.sku.trimmed : code) : name,
                    code: code,
                    qty: entry.hasQty ? entry.qty : 0,
                    price: entry.price
                )
                product.cost = entry.cost
                product.sku = entry.sku.trimmed
                context.insert(product)
                index.add(product)
                result.added += 1
            }
        }

        try? context.save()
        if result.added + result.updated > 0 {
            AutoSync.request(context)
        }
        return result
    }
}

// MARK: - Formatting & parsing helpers

enum Formatters {
    static func number(
        _ value: Double,
        minFraction: Int = 0,
        maxFraction: Int = 2,
        grouping: Bool = true
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = minFraction
        formatter.maximumFractionDigits = max(minFraction, maxFraction)
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func date(_ date: Date, includeTime: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ar@numbers=latn")
        formatter.dateStyle = .medium
        formatter.timeStyle = includeTime ? .short : .none
        return formatter.string(from: date)
    }
}

extension String {
    /// Extracts the first usable image URL from a sheet cell (handles =IMAGE("..."),
    /// several links separated by comma/space/newline, protocol-relative links and Drive share links).
    var firstImageURL: URL? {
        var text = trimmed
        if text.isEmpty { return nil }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        if let range = text.range(of: #"https?://[^\s,;"'<>)\\]+"#, options: .regularExpression) {
            text = String(text[range])
        } else if let range = text.range(of: #"//[^\s,;"'<>)\\]+"#, options: .regularExpression) {
            text = "https:" + String(text[range])
        } else {
            return nil
        }
        // Google Drive share links -> direct view links
        if let match = text.range(of: #"drive\.google\.com/file/d/([^/?]+)"#, options: .regularExpression) {
            let id = text[match].replacingOccurrences(of: "drive.google.com/file/d/", with: "")
            text = "https://drive.google.com/uc?export=view&id=\(id)"
        }
        if let url = URL(string: text) { return url }
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%"))) {
            return URL(string: encoded)
        }
        return nil
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts Arabic-Indic and Persian digits to Western digits and normalizes separators.
    var normalizedDigits: String {
        var output = ""
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669:
                if let converted = UnicodeScalar(scalar.value - 0x0660 + 48) {
                    output.unicodeScalars.append(converted)
                }
            case 0x06F0...0x06F9:
                if let converted = UnicodeScalar(scalar.value - 0x06F0 + 48) {
                    output.unicodeScalars.append(converted)
                }
            case 0x066B:
                output.append(".")
            case 0x066C, 0x060C:
                break
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Key used to compare product codes.
    var codeKey: String {
        normalizedDigits.trimmed.lowercased()
    }

    /// Lenient numeric parsing: Arabic digits, "1,234.50", "1.234,50" and "21,5".
    var parsedDouble: Double? {
        var cleaned = ""
        for character in normalizedDigits {
            if character.isASCII && (character.isNumber || character == "." || character == "," || character == "-") {
                cleaned.append(character)
            }
        }
        if cleaned.isEmpty { return nil }

        let lastDot = cleaned.lastIndex(of: ".")
        let lastComma = cleaned.lastIndex(of: ",")
        let dotCount = cleaned.filter { $0 == "." }.count
        let commaCount = cleaned.filter { $0 == "," }.count

        if let dot = lastDot, let comma = lastComma {
            if comma > dot {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if let comma = lastComma {
            let digitsAfter = cleaned.distance(from: comma, to: cleaned.endIndex) - 1
            let integerPart = String(cleaned[cleaned.startIndex..<comma])
            if commaCount == 1 && (digitsAfter != 3 || integerPart == "0") {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if dotCount > 1 {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
        }
        return Double(cleaned)
    }
}


// MARK: - Invoice kind

enum InvoiceKind {
    static let sale = "sale"
    static let supply = "supply"
}

extension Invoice {
    var isSupply: Bool { kind == InvoiceKind.supply }
}

// MARK: - Stock deduction on preparation

extension InventoryService {
    /// يخصم كمية الصنف من المخزون (بحد أقصى الموجود، ومبينزلش عن صفر) ويسجّل المخصوم.
    static func deduct(_ item: InvoiceItem, products: [Product]) {
        guard item.stockDeducted == 0 else { return }
        guard let product = StockMatcher(products: products).info(for: item).product else { return }
        let amount = min(max(product.qty, 0), max(item.qty, 0))
        guard amount > 0 else { return }
        product.qty -= amount
        product.updatedAt = Date()
        item.stockDeducted = amount
        if let context = product.modelContext { AutoSync.request(context) }
    }

    /// يرجّع للمخزون اللي اتخصم قبل كده لنفس الصنف.
    static func restore(_ item: InvoiceItem, products: [Product]) {
        guard item.stockDeducted > 0 else { return }
        if let product = StockMatcher(products: products).info(for: item).product {
            product.qty += item.stockDeducted
            product.updatedAt = Date()
            if let context = product.modelContext { AutoSync.request(context) }
        }
        item.stockDeducted = 0
    }
}

// MARK: - Invoice status

enum InvoiceStatus {
    static let new = "new"
    static let preparing = "preparing"
    static let done = "done"
}

extension Notification.Name {
    static let goToPreparationTab = Notification.Name("goToPreparationTab")
}

extension Product {
    /// مفتاح ثابت للصنف: الـ SKU لو موجود وإلا الكود
    var matchKey: String {
        let k = sku.codeKey
        return k.isEmpty ? code.codeKey : k
    }
}

// MARK: - Stock matching

enum StockState {
    case available      // الموجود يكفي
    case partial        // موجود لكن أقل من المطلوب
    case out            // معروف في المخزون لكن الكمية 0
    case notFound       // مش موجود في المخزون
}

struct StockInfo {
    var product: Product?
    var state: StockState
    var stock: Double
    var missing: Double

    var isFullyAvailable: Bool { state == .available }
}

/// فهرس للمنتجات: الـ SKU أولًا (لأنه فريد)، بعدين الباركود، بعدين الاسم.
/// منتجين ممكن يشتركوا في نفس الباركود، فمنعتبرهمش نفس المنتج لو الـ SKU مختلف.
struct ProductIndex {
    private var bySKU: [String: Product] = [:]
    private var byCode: [String: Product] = [:]
    private var byName: [String: Product] = [:]
    private var byKey: [String: Product] = [:]

    func product(matchKey key: String) -> Product? {
        let k = key.codeKey
        return k.isEmpty ? nil : byKey[k]
    }

    init(products: [Product]) {
        for product in products { add(product) }
    }

    mutating func add(_ product: Product) {
        let mk = product.matchKey
        if !mk.isEmpty && byKey[mk] == nil { byKey[mk] = product }
        let sku = product.sku.codeKey
        if !sku.isEmpty { bySKU[sku] = product }
        let code = product.code.codeKey
        if !code.isEmpty && byCode[code] == nil { byCode[code] = product }
        let name = product.name.trimmed.lowercased()
        if !name.isEmpty && byName[name] == nil { byName[name] = product }
    }

    func find(sku: String, code: String, name: String) -> Product? {
        let skuKey = sku.codeKey
        let codeKey = code.codeKey
        let nameKey = name.trimmed.lowercased()

        func compatible(_ product: Product) -> Bool {
            let other = product.sku.codeKey
            return skuKey.isEmpty || other.isEmpty || other == skuKey
        }

        if !skuKey.isEmpty, let product = bySKU[skuKey] { return product }
        if !codeKey.isEmpty, let product = byCode[codeKey], compatible(product) { return product }
        // أحيانًا الكود اللي في الفاتورة هو الـ SKU نفسه
        if !codeKey.isEmpty, let product = bySKU[codeKey] { return product }
        if !nameKey.isEmpty, let product = byName[nameKey], compatible(product) { return product }
        return nil
    }
}

struct StockMatcher {
    private let index: ProductIndex

    init(products: [Product]) {
        index = ProductIndex(products: products)
    }

    /// سعر البيع من المخزون بنفس طريقة مطابقة الصنف (باركود، SKU، ثم الاسم)
    func salePrice(for item: InvoiceItem) -> Double? {
        guard let price = info(for: item).product?.price, price > 0 else { return nil }
        return price
    }

    func info(for item: InvoiceItem) -> StockInfo {
        // مطابقة اتأكدت (أو اتعملت تلقائيًا) بحيث الاسم يختلف عن الشيت
        let match = index.product(matchKey: item.matchedKey)
            ?? index.find(sku: "", code: item.code, name: item.name)
        guard let product = match else {
            return StockInfo(product: nil, state: .notFound, stock: 0, missing: item.qty)
        }
        let stock = max(product.qty, 0)
        if stock >= item.qty {
            return StockInfo(product: product, state: .available, stock: stock, missing: 0)
        }
        return StockInfo(
            product: product,
            state: stock > 0 ? .partial : .out,
            stock: stock,
            missing: item.qty - stock
        )
    }
}

/// صف يعرض حالة المخزون تحت الصنف
struct StockBadge: View {
    let info: StockInfo

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        switch info.state {
        case .available:
            return "الموجود: \(Formatters.number(info.stock, maxFraction: 3))"
        case .partial:
            return "الموجود: \(Formatters.number(info.stock, maxFraction: 3)) — ناقص \(Formatters.number(info.missing, maxFraction: 3))"
        case .out:
            return "الموجود: 0 — ناقص \(Formatters.number(info.missing, maxFraction: 3))"
        case .notFound:
            return "غير موجود في المخزون"
        }
    }

    private var icon: String {
        switch info.state {
        case .available: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .out, .notFound: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch info.state {
        case .available: return .green
        case .partial: return .orange
        case .out, .notFound: return .red
        }
    }
}
