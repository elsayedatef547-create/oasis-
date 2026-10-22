import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Home

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var isProcessing = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                if invoices.isEmpty {
                    ContentUnavailableView(
                        "لا توجد فواتير",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("اضغط على «رفع فاتورة جديدة» لتحليل فاتورة وإضافتها.")
                    )
                } else {
                    List {
                        ForEach(invoices) { invoice in
                            NavigationLink {
                                InvoiceDetailView(invoice: invoice)
                            } label: {
                                InvoiceRow(invoice: invoice)
                            }
                        }
                        .onDelete(perform: deleteInvoices)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("الفواتير")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ArchiveView()
                    } label: {
                        Label("الأرشيف", systemImage: "archivebox")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                uploadMenu
            }
            .overlay {
                if isProcessing {
                    processingOverlay
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { await loadPhoto(newValue) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(isPresented: $showCamera) { image in
                Task { await process(image: image) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFileImporter) {
            DocumentPicker { url in
                showFileImporter = false
                handleImport(.success([url]))
            } onCancel: {
                showFileImporter = false
            }
            .ignoresSafeArea()
        }
        .alert("خطأ", isPresented: $showError) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: Subviews

    private var uploadMenu: some View {
        Menu {
            Button {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = true
                } else {
                    present(error: "الكاميرا غير متاحة على هذا الجهاز.")
                }
            } label: {
                Label("التقاط صورة بالكاميرا", systemImage: "camera.fill")
            }

            Button {
                showPhotoPicker = true
            } label: {
                Label("اختيار من الصور", systemImage: "photo.on.rectangle")
            }

            Button {
                // Let the menu finish dismissing before presenting the picker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showFileImporter = true
                }
            } label: {
                Label("اختيار ملف PDF أو صورة", systemImage: "doc.fill")
            }
        } label: {
            Label("رفع فاتورة جديدة", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.indigo, in: Capsule())
                .foregroundStyle(.white)
        }
        .disabled(isProcessing)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("جاري تحليل الفاتورة...")
                    .font(.headline)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Actions

    private func deleteInvoices(at offsets: IndexSet) {
        let products = (try? modelContext.fetch(FetchDescriptor<Product>())) ?? []
        for index in offsets {
            for item in invoices[index].items {
                InventoryService.restore(item, products: products)
            }
            modelContext.delete(invoices[index])
        }
        try? modelContext.save()
    }

    private func present(error message: String) {
        errorMessage = message
        showError = true
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                present(error: "تعذّر تحميل الصورة المختارة.")
                return
            }
            await process(image: image)
        } catch {
            present(error: error.localizedDescription)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            present(error: error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            // Read while the security-scoped access is guaranteed to be valid.
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                present(error: "تعذّر قراءة الملف.")
                return
            }
            let isPDF = url.pathExtension.lowercased() == "pdf" || data.starts(with: Data("%PDF".utf8))
            Task { await importData(data, isPDF: isPDF) }
        }
    }

    @MainActor
    private func importData(_ data: Data, isPDF: Bool) async {
        if isPDF {
            await runExtraction(data: data, mimeType: "application/pdf", preview: nil)
        } else if let image = UIImage(data: data) {
            await process(image: image)
        } else {
            present(error: "نوع الملف غير مدعوم.")
        }
    }

    @MainActor
    private func process(image: UIImage) async {
        guard let jpeg = GeminiService.prepareImage(image) else {
            present(error: "تعذّر معالجة الصورة.")
            return
        }
        await runExtraction(data: jpeg, mimeType: "image/jpeg", preview: jpeg)
    }

    @MainActor
    private func runExtraction(data: Data, mimeType: String, preview: Data?) async {
        isProcessing = true
        defer { isProcessing = false }

        do {
            let result = try await GeminiService.extractInvoice(from: data, mimeType: mimeType)
            let extracted = result.items

            let invoiceDate = result.date ?? Date()
            let invoice = Invoice(
                title: result.invoiceNumber.isEmpty
                    ? "فاتورة \(Formatters.date(invoiceDate, includeTime: result.date == nil))"
                    : "فاتورة \(result.invoiceNumber)",
                supplier: result.supplier,
                date: invoiceDate,
                imageData: preview
            )
            modelContext.insert(invoice)

            for (index, entry) in extracted.enumerated() {
                let item = InvoiceItem(
                    name: entry.name,
                    code: entry.code,
                    qty: entry.qty,
                    unitPrice: entry.unitPrice,
                    total: entry.total,
                    sortIndex: index
                )
                modelContext.insert(item)
                item.invoice = invoice
            }

            invoice.recalculateTotal()
            try modelContext.save()

            // مطابقة الأسماء المختلفة عن الشيت (تلقائي لو نفس الاسم، وإلا اقتراح لتأكيدك)
            _ = await MatchService.resolve(invoice: invoice, in: modelContext)

            if extracted.isEmpty {
                present(error: "لم يتم العثور على أصناف في الفاتورة. يمكنك إضافتها يدوياً.")
            }
        } catch {
            present(error: error.localizedDescription)
        }
    }
}

// MARK: - Invoice row

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(invoice.title)
                        .font(.headline)
                        .lineLimit(1)
                    if invoice.isSupply {
                        Text("توريد")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.teal.opacity(0.18), in: Capsule())
                            .foregroundStyle(.teal)
                    }
                }
                Text(Formatters.date(invoice.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !invoice.supplier.isEmpty {
                    Text(invoice.supplier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.number(invoice.totalAmount, minFraction: 2))
                    .font(.subheadline.bold())
                Text("\(invoice.items.count) صنف")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Invoice detail

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// منتقي ملفات UIKit (PDF أو صورة). بيعمل نسخة محلية من الملف فمفيش مشاكل صلاحيات.
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.pdf, .image]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { parent.onCancel(); return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct InvoiceDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var invoice: Invoice
    @Query private var products: [Product]
    @State private var isMatching = false

    @State private var editingItem: InvoiceItem?
    @State private var shareItem: ShareItem?
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showReAddConfirm = false

    private var sortedItems: [InvoiceItem] {
        invoice.items.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// إجمالي الفاتورة من أسعار الشيت (المخزون) مش من أسعار الفاتورة الأصلية.
    private var computedTotal: Double { totalSale }

    private var totalSale: Double {
        let matcher = StockMatcher(products: products)
        return invoice.items.reduce(0) { partial, item in
            partial + item.qty * (matcher.salePrice(for: item) ?? 0)
        }
    }

    var body: some View {
        let matcher = StockMatcher(products: products)
        let infos = sortedItems.map { matcher.info(for: $0) }
        let availableCount = zip(sortedItems, infos).filter { $0.0.prepared || $0.1.isFullyAvailable }.count
        let missingCount = infos.count - availableCount
        let productIndex = ProductIndex(products: products)
        let suggestions: [(item: InvoiceItem, product: Product)] = sortedItems.compactMap { item in
            guard !item.prepared, !item.suggestedKey.isEmpty, productIndex.product(matchKey: item.matchedKey) == nil,
                  let product = productIndex.product(matchKey: item.suggestedKey) else { return nil }
            return (item, product)
        }
        let hasUnmatched = !invoice.isSupply && zip(sortedItems, infos).contains { !$0.0.prepared && $0.1.state == .notFound }
        return List {
            if !suggestions.isEmpty {
                Section("اقتراحات مطابقة — محتاجة تأكيدك") {
                    ForEach(suggestions, id: \.item.persistentModelID) { entry in
                        MatchSuggestionRow(
                            item: entry.item,
                            product: entry.product,
                            onAccept: { MatchService.accept(entry.item, product: entry.product, in: modelContext) },
                            onReject: { MatchService.reject(entry.item, in: modelContext) }
                        )
                    }
                }
            }
            if hasUnmatched {
                Section {
                    Button {
                        isMatching = true
                        Task {
                            let outcome = await MatchService.resolve(invoice: invoice, in: modelContext)
                            isMatching = false
                            if let error = outcome.aiError {
                                alertMessage = "المطابقة المحلية اتعملت، لكن الذكاء الاصطناعي مردّش: \(error)"
                                showAlert = true
                            } else if outcome.auto + outcome.suggested == 0 {
                                alertMessage = "ملقيتش أصناف مشابهة في الشيت للأصناف اللي ناقصة."
                                showAlert = true
                            }
                        }
                    } label: {
                        HStack {
                            if isMatching { ProgressView() }
                            Label("دوّر على الأصناف الناقصة في الشيت بالتشابه", systemImage: "sparkle.magnifyingglass")
                        }
                    }
                    .disabled(isMatching)
                }
            }
            if !invoice.items.isEmpty && !invoice.isSupply {
                Section("المخزون مقابل الفاتورة") {
                    HStack {
                        Label("موجود: \(availableCount)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Label("ناقص: \(missingCount)", systemImage: "xmark.circle.fill")
                            .foregroundStyle(missingCount > 0 ? .red : .secondary)
                    }
                    .font(.subheadline.weight(.semibold))

                    if invoice.status == InvoiceStatus.new {
                        Button {
                            startPreparation()
                        } label: {
                            Label("تجهيز", systemImage: "checklist")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    } else {
                        Button {
                            NotificationCenter.default.post(name: .goToPreparationTab, object: nil)
                        } label: {
                            Label(invoice.status == InvoiceStatus.done ? "تم التجهيز — فتح في التجهيز" : "قيد التجهيز — فتح في التجهيز",
                                  systemImage: "arrow.right.circle")
                        }
                    }
                }
            }

            Section("معلومات الفاتورة") {
                Picker("نوع الفاتورة", selection: $invoice.kind) {
                    Text("بيع / طلب").tag(InvoiceKind.sale)
                    Text("توريد").tag(InvoiceKind.supply)
                }
                .pickerStyle(.segmented)
                TextField("العنوان", text: $invoice.title)
                TextField("المورد", text: $invoice.supplier)
                DatePicker("التاريخ", selection: $invoice.date)
                TextField("ملاحظات", text: $invoice.notes, axis: .vertical)
                    .lineLimit(1...4)
            }

            if let data = invoice.imageData, let uiImage = UIImage(data: data) {
                Section("صورة الفاتورة") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity)
                }
            }

            Section("الأصناف (\(invoice.items.count))") {
                ForEach(sortedItems) { item in
                    Button {
                        if item.prepared {
                            alertMessage = "الصنف ده اتجهّز واتخصم من المخزون. ألغِ علامة التجهيز الأول لو عايز تعدّله."
                            showAlert = true
                        } else {
                            editingItem = item
                        }
                    } label: {
                        ItemRow(
                            item: item,
                            salePrice: matcher.salePrice(for: item),
                            stock: matcher.info(for: item),
                            showStockBadge: !item.prepared && !invoice.isSupply
                        )
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteItems)

                Button {
                    addItem()
                } label: {
                    Label("إضافة صنف", systemImage: "plus.circle")
                }
            }

            Section {
                HStack {
                    Text("إجمالي الفاتورة")
                        .font(.headline)
                    Spacer()
                    Text(Formatters.number(computedTotal, minFraction: 2))
                        .font(.title3.bold())
                        .foregroundStyle(.indigo)
                }
            }

            Section {
                Button {
                    if invoice.addedToInventory {
                        showReAddConfirm = true
                    } else {
                        addToInventory()
                    }
                } label: {
                    Label(
                        invoice.addedToInventory
                            ? "اتضافت للمخزون (إضافة مرة تانية؟)"
                            : (invoice.isSupply ? "تأكيد التوريد وزيادة المخزون" : "إضافة الأصناف إلى المخزون"),
                        systemImage: invoice.addedToInventory ? "checkmark.circle.fill" : "shippingbox.and.arrow.backward"
                    )
                }
                .disabled(invoice.items.isEmpty)
            }
        }
        .navigationTitle("تفاصيل الفاتورة")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    sharePDF()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(invoice.items.isEmpty)
            }
        }
        .sheet(item: $editingItem, onDismiss: {
            removeEmptyItems()
            invoice.totalAmount = computedTotal
            try? modelContext.save()
        }) { item in
            ItemEditView(item: item)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("تنبيه", isPresented: $showAlert) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog(
            "الفاتورة دي اتضافت للمخزون قبل كده. إضافتها تاني هتضاعف الكميات.",
            isPresented: $showReAddConfirm,
            titleVisibility: .visible
        ) {
            Button("أضف مرة تانية", role: .destructive) { addToInventory() }
            Button("إلغاء", role: .cancel) {}
        }
        .onChange(of: invoice.kind) { _, newKind in
            guard newKind == InvoiceKind.supply else { return }
            for item in invoice.items {
                InventoryService.restore(item, products: products)
                item.prepared = false
            }
            invoice.status = InvoiceStatus.new
            try? modelContext.save()
        }
        .onDisappear {
            invoice.totalAmount = computedTotal
            try? modelContext.save()
        }
    }

    // MARK: Actions

    private func deleteItems(at offsets: IndexSet) {
        let snapshot = sortedItems
        let toDelete = offsets.map { snapshot[$0] }
        for item in toDelete {
            InventoryService.restore(item, products: products)
            let identifier = item.persistentModelID
            invoice.items.removeAll { $0.persistentModelID == identifier }
            modelContext.delete(item)
        }
        invoice.totalAmount = computedTotal
        try? modelContext.save()
    }

    /// بيمسح الأصناف الفاضية (اتضافت بالغلط ومتملتش).
    private func removeEmptyItems() {
        let empties = invoice.items.filter {
            $0.name.trimmed.isEmpty && $0.code.trimmed.isEmpty && $0.total == 0
        }
        for item in empties {
            let identifier = item.persistentModelID
            invoice.items.removeAll { $0.persistentModelID == identifier }
            modelContext.delete(item)
        }
    }

    private func startPreparation() {
        invoice.status = InvoiceStatus.preparing
        for item in invoice.items {
            InventoryService.restore(item, products: products)
            item.prepared = false
        }
        try? modelContext.save()
        NotificationCenter.default.post(name: .goToPreparationTab, object: nil)
    }

    private func addItem() {
        let nextIndex = (invoice.items.map { $0.sortIndex }.max() ?? -1) + 1
        let item = InvoiceItem(name: "", sortIndex: nextIndex)
        modelContext.insert(item)
        item.invoice = invoice
        editingItem = item
    }

    private func sharePDF() {
        invoice.totalAmount = computedTotal
        let matcher = StockMatcher(products: products)
        do {
            let url = try PDFGenerator.writeTemporaryFile(
                for: invoice,
                salePrice: { matcher.salePrice(for: $0) }
            )
            InvoiceArchive.save(invoice, salePrice: { matcher.salePrice(for: $0) }, in: modelContext)
            shareItem = ShareItem(url: url)
        } catch {
            alertMessage = "تعذّر إنشاء ملف PDF: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func addToInventory() {
        let entries = sortedItems.map { item in
            InventoryEntry(name: item.name, code: item.code, qty: item.qty, price: 0, cost: item.unitPrice)
        }
        let result = InventoryService.merge(entries, mode: .addQuantity, in: modelContext)
        invoice.addedToInventory = true
        try? modelContext.save()
        alertMessage = "تمت الإضافة إلى المخزون: \(result.added) صنف جديد، \(result.updated) صنف محدّث."
        showAlert = true
    }
}

struct ItemRow: View {
    let item: InvoiceItem
    var salePrice: Double? = nil
    var stock: StockInfo? = nil
    var showStockBadge: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProductThumb(imageURL: stock?.product?.imageURL, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name.isEmpty ? "صنف بدون اسم" : item.name)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                if !item.code.isEmpty {
                    Text(item.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !item.matchedKey.isEmpty, let sheetName = stock?.product?.name {
                    Label(
                        "\(item.matchAuto ? "مطابق تلقائيًا" : "مطابق") مع: \(sheetName)",
                        systemImage: "link"
                    )
                    .font(.caption)
                    .foregroundStyle(.indigo)
                }
                Text("الكمية: \(Formatters.number(item.qty, maxFraction: 3))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let salePrice {
                    Text("سعر البيع (من الشيت): \(Formatters.number(salePrice, minFraction: 2))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text("مفيش سعر في الشيت")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if let stock, showStockBadge {
                    StockBadge(info: stock)
                }
            }
            Spacer()
            Text(salePrice.map { Formatters.number(item.qty * $0, minFraction: 2) } ?? "-")
                .font(.subheadline.bold())
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct ItemEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: InvoiceItem

    var body: some View {
        NavigationStack {
            Form {
                Section("بيانات الصنف") {
                    TextField("الاسم", text: $item.name)
                    TextField("الكود", text: $item.code)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("الكمية والسعر") {
                    HStack {
                        Text("الكمية")
                        Spacer()
                        TextField("0", value: $item.qty, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("سعر الوحدة")
                        Spacer()
                        TextField("0", value: $item.unitPrice, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("الإجمالي")
                        Spacer()
                        TextField("0", value: $item.total, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("تعديل الصنف")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
            .onChange(of: item.qty) { _, _ in
                item.total = item.qty * item.unitPrice
            }
            .onChange(of: item.unitPrice) { _, _ in
                item.total = item.qty * item.unitPrice
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Camera picker

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            parent.isPresented = false
            if let image {
                parent.onImage(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
