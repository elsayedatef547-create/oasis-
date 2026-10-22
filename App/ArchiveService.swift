import SwiftUI
import SwiftData
import PDFKit

// MARK: - Model

/// نسخة مجمّدة من الفاتورة (PDF + ملخص) بتتحفظ في أرشيف منفصل.
/// حتى لو الفاتورة الأصلية اتمسحت من الرئيسية أو المخزون اتغيّر، الأرشيف يفضل زي ما اتصدّر.
@Model
final class ArchivedInvoice {
    var key: String = ""
    var title: String = ""
    var supplier: String = ""
    var invoiceDate: Date = Date()
    var archivedAt: Date = Date()
    var itemCount: Int = 0
    var pieceCount: Double = 0
    var totalSale: Double = 0
    @Attribute(.externalStorage) var pdfData: Data?

    init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}

// MARK: - Service

enum InvoiceArchive {
    /// يحفظ (أو يحدّث) نسخة الفاتورة في الأرشيف. بنفس الفاتورة مبيتكررش؛ بيتحدّث بس.
    @MainActor
    static func save(
        _ invoice: Invoice,
        items: [InvoiceItem]? = nil,
        salePrice: (InvoiceItem) -> Double?,
        in context: ModelContext
    ) {
        let list = (items ?? invoice.items).sorted { $0.sortIndex < $1.sortIndex }
        guard !list.isEmpty else { return }

        let key = "\(invoice.title)|\(Int(invoice.date.timeIntervalSince1970))"
        let existing = (try? context.fetch(FetchDescriptor<ArchivedInvoice>())) ?? []
        let entry = existing.first { $0.key == key } ?? {
            let new = ArchivedInvoice(key: key, title: invoice.title)
            context.insert(new)
            return new
        }()

        entry.title = invoice.title
        entry.supplier = invoice.supplier
        entry.invoiceDate = invoice.date
        entry.archivedAt = Date()
        entry.itemCount = list.count
        entry.pieceCount = list.reduce(0) { $0 + max($1.qty, 0) }
        entry.totalSale = list.reduce(0) { $0 + $1.qty * (salePrice($1) ?? 0) }
        entry.pdfData = PDFGenerator.generate(for: invoice, salePrice: salePrice, items: list)
        try? context.save()
    }
}

// MARK: - Views

struct ArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArchivedInvoice.archivedAt, order: .reverse) private var archived: [ArchivedInvoice]
    @State private var search = ""

    private var filtered: [ArchivedInvoice] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return archived }
        return archived.filter {
            $0.title.lowercased().contains(q) || $0.supplier.lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if archived.isEmpty {
                ContentUnavailableView(
                    "الأرشيف فاضي",
                    systemImage: "archivebox",
                    description: Text("أي فاتورة تعمل لها PDF أو تنهي تجهيزها بتتسجل هنا تلقائيًا وتفضل محفوظة.")
                )
            } else {
                List {
                    ForEach(filtered) { entry in
                        NavigationLink {
                            ArchiveDetailView(entry: entry)
                        } label: {
                            ArchiveRow(entry: entry)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(filtered[index]) }
                        try? modelContext.save()
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $search, prompt: "بحث برقم الفاتورة أو المورد")
            }
        }
        .navigationTitle("أرشيف الفواتير")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ArchiveRow: View {
    let entry: ArchivedInvoice

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.indigo.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "archivebox.fill").foregroundStyle(.indigo)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.headline).lineLimit(1)
                Text(Formatters.date(entry.archivedAt))
                    .font(.caption).foregroundStyle(.secondary)
                if !entry.supplier.isEmpty {
                    Text(entry.supplier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.number(entry.totalSale, minFraction: 2)).font(.subheadline.bold())
                Text("\(Formatters.number(entry.pieceCount, maxFraction: 3)) قطعة")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ArchiveDetailView: View {
    let entry: ArchivedInvoice
    @State private var shareItem: ShareItem?

    var body: some View {
        Group {
            if let data = entry.pdfData {
                PDFKitView(data: data)
            } else {
                ContentUnavailableView("الملف غير متاح", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    share()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(entry.pdfData == nil)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func share() {
        guard let data = entry.pdfData else { return }
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var name = entry.title.components(separatedBy: forbidden).joined(separator: "-").trimmed
        if name.isEmpty { name = "invoice" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        if (try? data.write(to: url, options: .atomic)) != nil {
            shareItem = ShareItem(url: url)
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
