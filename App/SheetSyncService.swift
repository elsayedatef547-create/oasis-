import Foundation
import SwiftData
import SwiftUI

enum SheetSyncError: LocalizedError {
    case missingConfig
    case badURL
    case notJSON
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "أدخل رابط الشيت وكلمة السر أولاً."
        case .badURL:
            return "رابط الشيت غير صالح."
        case .notJSON:
            return "الرد مش صحيح. تأكد إن السكربت منشور (Web app) وصلاحية الوصول Anyone."
        case .server(let message):
            return message == "unauthorized" ? "كلمة السر غير صحيحة." : "خطأ من الشيت: \(message)"
        }
    }
}

struct SheetRow {
    var barcode: String
    var sku: String
    var name: String
    var price: Double      // Sales Price
    var cost: Double       // Cost
    var qty: Double?       // Existencias (nil لو الخانة نص مثل "Sin dato")
    var image: String
}

struct SheetSyncResult {
    var added = 0
    var updated = 0
    var pushed = 0
}

enum SheetSyncService {
    static let urlKey = "sheet_sync_url"
    static let passwordAccount = "sheet_sync_password"
    static let lastSyncKey = "sheet_last_sync"
    static let lastPushKey = "sheet_last_push"

    // MARK: Pull

    static func pull(url: URL, password: String) async throws -> [SheetRow] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SheetSyncError.badURL
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        var query = components.percentEncodedQuery.map { $0 + "&" } ?? ""
        query += "key=\(encodedPassword)"
        components.percentEncodedQuery = query
        guard let finalURL = components.url else { throw SheetSyncError.badURL }

        var request = URLRequest(url: finalURL)
        request.timeoutInterval = 90
        let (data, _) = try await URLSession.shared.data(for: request)

        let json = try object(from: data)
        guard let rawRows = json["rows"] as? [[String: Any]] else { return [] }

        return rawRows.compactMap { raw -> SheetRow? in
            let barcode = string(raw["barcode"]).trimmed
            let sku = string(raw["sku"]).trimmed
            if barcode.isEmpty && sku.isEmpty { return nil }
            return SheetRow(
                barcode: barcode,
                sku: sku,
                name: string(raw["name"]).trimmed,
                price: double(raw["price"]) ?? 0,
                cost: double(raw["cost"]) ?? 0,
                qty: double(raw["qty"]),
                image: string(raw["image"]).trimmed
            )
        }
    }

    // MARK: Push

    static func push(url: URL, password: String, rows: [SheetRow]) async throws {
        let payloadRows: [[String: Any]] = rows.map { row in
            [
                "barcode": row.barcode,
                "sku": row.sku,
                "name": row.name,
                "price": row.price,
                "cost": row.cost,
                "qty": row.qty ?? 0,
                "image": row.image
            ]
        }
        let body: [String: Any] = ["key": password, "rows": payloadRows]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        _ = try object(from: data)
    }

    // MARK: Full sync (pull then push)

    @MainActor
    static func sync(in context: ModelContext) async throws -> SheetSyncResult {
        let urlString = (UserDefaults.standard.string(forKey: urlKey) ?? "").trimmed
        let password = KeychainHelper.read(account: passwordAccount) ?? ""
        guard !urlString.isEmpty, !password.isEmpty else { throw SheetSyncError.missingConfig }
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw SheetSyncError.badURL
        }

        var result = SheetSyncResult()

        // 1) سحب من الشيت ودمجه محلياً. الصنف اللي اتعدّل في التطبيق بعد آخر مزامنة
        //    بنحافظ على تعديلاته المحلية (كمية/سعر/اسم) وبنرفعها للشيت بدل ما تتمسح.
        let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        let remote = try await pull(url: url, password: password)
        let existing = (try? context.fetch(FetchDescriptor<Product>())) ?? []

        var index = ProductIndex(products: existing)

        for row in remote {
            let match = index.find(sku: row.sku, code: row.barcode, name: "")

            if let product = match {
                // لو دي أول مزامنة، أي منتج اتعدّل محليًا بعد إنشائه (زي خصم التجهيز) يتحسب تعديل محلي
                let localChanged = lastSync.map { product.updatedAt > $0 }
                    ?? (product.updatedAt.timeIntervalSince(product.createdAt) > 1)
                if !localChanged {
                    if !row.name.isEmpty { product.name = row.name }
                    if row.price > 0 { product.price = row.price }
                    if row.cost > 0 { product.cost = row.cost }
                    if let qty = row.qty { product.qty = qty }
                }
                if product.code.trimmed.isEmpty && !row.barcode.isEmpty { product.code = row.barcode }
                if !row.sku.isEmpty { product.sku = row.sku }
                if !row.image.isEmpty { product.imageURL = row.image }
                index.add(product)
                result.updated += 1
            } else {
                let product = Product(
                    name: row.name.isEmpty ? (row.sku.isEmpty ? row.barcode : row.sku) : row.name,
                    code: row.barcode,
                    qty: row.qty ?? 0,
                    price: row.price
                )
                product.sku = row.sku
                product.cost = row.cost
                product.imageURL = row.image
                context.insert(product)
                index.add(product)
                result.added += 1
            }
        }
        try? context.save()

        // 2) رفع المنتجات (اللي ليها باركود أو SKU) للشيت
        let all = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        let rows = all.compactMap { SheetSyncService.sheetRow(for: $0) }
        if !rows.isEmpty {
            try await push(url: url, password: password, rows: rows)
        }
        result.pushed = rows.count
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        UserDefaults.standard.set(Date(), forKey: lastPushKey)
        return result
    }

    // MARK: Auto push (يرفع الأصناف اللي اتعدّلت بس)

    static func sheetRow(for product: Product) -> SheetRow? {
        let barcode = product.code.trimmed
        let sku = product.sku.trimmed
        if barcode.isEmpty && sku.isEmpty { return nil }
        return SheetRow(
            barcode: barcode,
            sku: sku,
            name: product.name,
            price: product.price,
            cost: product.cost,
            qty: product.qty,
            image: product.imageURL
        )
    }

    /// يرفع للشيت الأصناف اللي اتعدّلت من آخر رفع. لو فشل (مفيش نت مثلًا) بيتعاد في أول تعديل أو فتح للتطبيق.
    @MainActor
    static func pushChanged(in context: ModelContext) async {
        let defaults = UserDefaults.standard
        let urlString = (defaults.string(forKey: urlKey) ?? "").trimmed
        let password = KeychainHelper.read(account: passwordAccount) ?? ""
        guard !urlString.isEmpty, !password.isEmpty,
              let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return }

        // لسه ما اتعملتش مزامنة أولى: نعمل مزامنة كاملة (سحب + دمج + رفع). التعديلات المحلية بتتحفظ ومبتتمسحش.
        guard let since = (defaults.object(forKey: lastPushKey) as? Date)
                ?? (defaults.object(forKey: lastSyncKey) as? Date) else {
            do {
                let result = try await sync(in: context)
                defaults.set("تمت أول مزامنة تلقائيًا: \(result.added) جديد، \(result.updated) محدّث، \(result.pushed) اترفع (\(Formatters.date(Date())))", forKey: AutoSync.statusKey)
            } catch {
                defaults.set("تعذّرت المزامنة الأولى: \(error.localizedDescription)", forKey: AutoSync.statusKey)
            }
            return
        }

        try? context.save()
        let all = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        let rows = all
            .filter { $0.updatedAt > since }
            .compactMap { SheetSyncService.sheetRow(for: $0) }
        guard !rows.isEmpty else { return }

        let stamp = Date()
        do {
            try await push(url: url, password: password, rows: rows)
            defaults.set(stamp, forKey: lastPushKey)
            defaults.set("اترفع للشيت تلقائيًا: \(rows.count) صنف (\(Formatters.date(stamp)))", forKey: AutoSync.statusKey)
        } catch {
            defaults.set("تعذّر الرفع التلقائي، هيتعاد تلقائيًا: \(error.localizedDescription)", forKey: AutoSync.statusKey)
        }
    }

    // MARK: Helpers

    private static func object(from data: Data) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SheetSyncError.notJSON
        }
        if let ok = json["ok"] as? Bool, !ok {
            throw SheetSyncError.server((json["error"] as? String) ?? "unknown")
        }
        return json
    }

    private static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return s.parsedDouble }
        return nil
    }
}

// MARK: - Settings section (داخل Form في SettingsView)

struct SheetSyncSection: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SheetSyncService.urlKey) private var sheetURL = ""
    @AppStorage(AutoSync.enabledKey) private var autoPush = true
    @AppStorage(AutoSync.statusKey) private var autoStatus = ""

    @State private var password = ""
    @State private var isSyncing = false
    @State private var status = ""
    @State private var isError = false

    var body: some View {
        Section {
            TextField("رابط السكربت (Web app URL)", text: $sheetURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("كلمة السر", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Toggle("رفع التعديلات للشيت تلقائيًا", isOn: $autoPush)

            if autoPush && !autoStatus.isEmpty {
                Text(autoStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await run() }
            } label: {
                HStack {
                    Label("حفظ ومزامنة الآن", systemImage: "arrow.triangle.2.circlepath")
                    if isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isSyncing || sheetURL.trimmed.isEmpty || password.isEmpty)

            if !status.isEmpty {
                Label(status, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(isError ? Color.red : Color.green)
            }
        } header: {
            Text("مزامنة مع Google Sheets")
        } footer: {
            Text("الأعمدة المستخدمة: B الاسم، D المرجع الداخلي (SKU)، E الباركود، F سعر البيع، G التكلفة، M المخزون، J رابط الصورة (قراءة فقط). باقي الأعمدة ما بتتغيرش.")
        }
        .onAppear {
            password = KeychainHelper.read(account: SheetSyncService.passwordAccount) ?? ""
        }
    }

    @MainActor
    private func run() async {
        isSyncing = true
        defer { isSyncing = false }
        KeychainHelper.save(password, account: SheetSyncService.passwordAccount)
        do {
            let result = try await SheetSyncService.sync(in: modelContext)
            isError = false
            status = "تمت المزامنة: \(result.added) جديد، \(result.updated) محدّث، \(result.pushed) اترفع للشيت."
        } catch {
            isError = true
            status = error.localizedDescription
        }
    }
}

// MARK: - Auto push trigger

enum AutoSync {
    static let enabledKey = "sheet_auto_push"
    static let statusKey = "sheet_auto_status"

    @MainActor private static var pending: Task<Void, Never>?

    /// آمن للاستدعاء من أي مكان بعد أي تعديل في المخزون. بيستنى ثانيتين ونص (يجمّع التعديلات) وبعدين يرفع.
    static func request(_ context: ModelContext) {
        Task { @MainActor in
            let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
            guard enabled else { return }
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                await SheetSyncService.pushChanged(in: context)
            }
        }
    }
}
