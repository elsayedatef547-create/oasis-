import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backup file format

struct BackupItem: Codable {
    var name: String
    var code: String
    var qty: Double
    var unitPrice: Double
    var total: Double
    var sortIndex: Int
    var prepared: Bool
}

struct BackupInvoice: Codable {
    var title: String
    var supplier: String
    var date: Date
    var totalAmount: Double
    var notes: String
    var status: String
    var addedToInventory: Bool
    var kind: String?
    var imageData: Data?
    var items: [BackupItem]
}

struct BackupFile: Codable {
    var version: Int
    var exportedAt: Date
    var invoices: [BackupInvoice]
}

enum BackupError: LocalizedError {
    case unreadable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "تعذّر قراءة الملف. تأكد إنه ملف نسخة احتياطية من التطبيق."
        case .unsupported:
            return "الملف ده من إصدار أحدث من التطبيق. حدّث التطبيق وجرّب تاني."
        }
    }
}

struct BackupImportResult {
    var added = 0
    var skipped = 0
}

// MARK: - Service

enum BackupService {
    static let currentVersion = 1

    /// بيعمل ملف JSON مؤقت فيه كل الفواتير وأصنافها (والصور).
    static func makeBackupFile(from invoices: [Invoice]) throws -> URL {
        let backup = BackupFile(
            version: currentVersion,
            exportedAt: Date(),
            invoices: invoices.map { invoice in
                BackupInvoice(
                    title: invoice.title,
                    supplier: invoice.supplier,
                    date: invoice.date,
                    totalAmount: invoice.totalAmount,
                    notes: invoice.notes,
                    status: invoice.status,
                    addedToInventory: invoice.addedToInventory,
                    kind: invoice.kind,
                    imageData: invoice.imageData,
                    items: invoice.items
                        .sorted { $0.sortIndex < $1.sortIndex }
                        .map { item in
                            BackupItem(
                                name: item.name,
                                code: item.code,
                                qty: item.qty,
                                unitPrice: item.unitPrice,
                                total: item.total,
                                sortIndex: item.sortIndex,
                                prepared: item.prepared
                            )
                        }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InvoiceScanner-\(stamp.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// بيضيف الفواتير الجديدة بس. اللي موجودة عندك بنفس العنوان والتاريخ والإجمالي وعدد الأصناف بتتخطّى.
    /// ملاحظة: كميات المخزون مبتتغيّرش من الاستيراد (المخزون بييجي من الشيت).
    static func importBackup(from url: URL, into context: ModelContext) throws -> BackupImportResult {
        guard let data = try? Data(contentsOf: url) else { throw BackupError.unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(BackupFile.self, from: data) else {
            throw BackupError.unreadable
        }
        guard backup.version <= currentVersion else { throw BackupError.unsupported }

        let existing = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
        var keys = Set(existing.map { signature(title: $0.title, date: $0.date, total: $0.totalAmount, count: $0.items.count) })

        var result = BackupImportResult()
        for entry in backup.invoices {
            let key = signature(title: entry.title, date: entry.date, total: entry.totalAmount, count: entry.items.count)
            if keys.contains(key) {
                result.skipped += 1
                continue
            }

            let invoice = Invoice(
                title: entry.title,
                supplier: entry.supplier,
                date: entry.date,
                totalAmount: entry.totalAmount,
                notes: entry.notes,
                imageData: entry.imageData
            )
            invoice.status = entry.status
            invoice.addedToInventory = entry.addedToInventory
            invoice.kind = entry.kind ?? InvoiceKind.sale
            context.insert(invoice)

            for source in entry.items {
                let item = InvoiceItem(
                    name: source.name,
                    code: source.code,
                    qty: source.qty,
                    unitPrice: source.unitPrice,
                    total: source.total,
                    sortIndex: source.sortIndex
                )
                item.prepared = source.prepared
                context.insert(item)
                item.invoice = invoice
            }

            keys.insert(key)
            result.added += 1
        }

        try? context.save()
        return result
    }

    private static func signature(title: String, date: Date, total: Double, count: Int) -> String {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let cents = Int((total * 100).rounded())
        return "\(title)|\(seconds)|\(cents)|\(count)"
    }
}

// MARK: - Settings section

struct BackupSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    @State private var shareItem: ShareItem?
    @State private var showImporter = false
    @State private var message = ""
    @State private var isError = false

    var body: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                Label("تصدير الفواتير (ملف نسخة احتياطية)", systemImage: "square.and.arrow.up")
            }
            .disabled(invoices.isEmpty)

            Button {
                showImporter = true
            } label: {
                Label("استيراد فواتير من ملف", systemImage: "square.and.arrow.down")
            }

            if !message.isEmpty {
                Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(isError ? Color.red : Color.green)
            }
        } header: {
            Text("نسخة احتياطية للفواتير")
        } footer: {
            Text("الملف فيه الفواتير وأصنافها وصورها. ابعته لزميلك (واتساب، AirDrop…) وهو يستورده من هنا. المخزون بيتشارك عن طريق مزامنة الشيت، ومفتاح Gemini بيتحط على كل جهاز لوحده.")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(types: [UTType.json]) { url in
                showImporter = false
                importBackup(from: url)
            } onCancel: {
                showImporter = false
            }
            .ignoresSafeArea()
        }
    }

    private func exportBackup() {
        do {
            shareItem = ShareItem(url: try BackupService.makeBackupFile(from: invoices))
            message = ""
        } catch {
            isError = true
            message = "تعذّر إنشاء الملف: \(error.localizedDescription)"
        }
    }

    private func importBackup(from url: URL) {
        do {
            let result = try BackupService.importBackup(from: url, into: modelContext)
            isError = false
            message = "تم الاستيراد: \(result.added) فاتورة جديدة، \(result.skipped) موجودة قبل كده."
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}
