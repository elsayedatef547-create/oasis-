import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Inventory

struct InventoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Product.name) private var products: [Product]

    @State private var searchText = ""
    @State private var editingProduct: Product?
    @State private var showAddSheet = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument = XLSXDocument(data: Data())
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showBarcodeSearch = false
    @State private var isSyncing = false

    private var filteredProducts: [Product] {
        let query = searchText.trimmed
        if query.isEmpty { return products }
        let normalized = query.normalizedDigits.lowercased()
        return products.filter { product in
            product.name.lowercased().contains(query.lowercased())
                || product.code.normalizedDigits.lowercased().contains(normalized)
                || product.sku.lowercased().contains(query.lowercased())
        }
    }

    private var totalValue: Double {
        products.reduce(0) { $0 + $1.qty * $1.price }
    }

    var body: some View {
        NavigationStack {
            Group {
                if products.isEmpty {
                    ContentUnavailableView(
                        "المخزون فارغ",
                        systemImage: "shippingbox",
                        description: Text("أضف منتجاً أو استورد ملف Excel لبدء إدارة المخزون.")
                    )
                } else {
                    List {
                        Section {
                            HStack {
                                summaryCell(title: "عدد المنتجات", value: "\(products.count)")
                                Divider()
                                summaryCell(title: "قيمة المخزون", value: Formatters.number(totalValue, minFraction: 2))
                            }
                        }

                        Section {
                            ForEach(filteredProducts) { product in
                                Button {
                                    editingProduct = product
                                } label: {
                                    ProductRow(product: product)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete(perform: deleteProducts)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("المخزون")
            .searchable(text: $searchText, prompt: "ابحث بالاسم أو الكود")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("استيراد من Excel", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            exportDocument = XLSXDocument(data: XLSXService.makeWorkbook(products: products))
                            showExporter = true
                        } label: {
                            Label("تصدير إلى Excel", systemImage: "square.and.arrow.up")
                        }
                        .disabled(products.isEmpty)

                        Button {
                            Task { await syncNow() }
                        } label: {
                            Label("مزامنة مع الشيت", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isSyncing)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showBarcodeSearch = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                }
            }
        }
        .sheet(item: $editingProduct) { product in
            ProductFormView(product: product)
        }
        .sheet(isPresented: $showAddSheet) {
            ProductFormView(product: nil)
        }
        .fullScreenCover(isPresented: $showBarcodeSearch) {
            BarcodeSearchSheet { code in
                searchText = code
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(types: [UTType.excelXLSX]) { url in
                showImporter = false
                handleImport(.success([url]))
            } onCancel: {
                showImporter = false
            }
            .ignoresSafeArea()
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: UTType.excelXLSX,
            defaultFilename: "Inventory"
        ) { result in
            switch result {
            case .success:
                alertMessage = "تم تصدير المخزون بنجاح."
                showAlert = true
            case .failure(let error):
                alertMessage = "فشل التصدير: \(error.localizedDescription)"
                showAlert = true
            }
        }
        .alert("تنبيه", isPresented: $showAlert) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: Helpers

    private func summaryCell(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(.indigo)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let result = try await SheetSyncService.sync(in: modelContext)
            alertMessage = "تمت المزامنة: \(result.added) جديد، \(result.updated) محدّث، \(result.pushed) اترفع للشيت."
        } catch {
            alertMessage = error.localizedDescription
        }
        showAlert = true
    }

    private func deleteProducts(at offsets: IndexSet) {
        let snapshot = filteredProducts
        for index in offsets {
            modelContext.delete(snapshot[index])
        }
        try? modelContext.save()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertMessage = "فشل الاستيراد: \(error.localizedDescription)"
            showAlert = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                let entries = try XLSXService.readEntries(from: data)
                let summary = InventoryService.merge(entries, mode: .replaceQuantity, in: modelContext)
                alertMessage = "تم الاستيراد: \(summary.added) منتج جديد، \(summary.updated) منتج محدّث."
                showAlert = true
            } catch {
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }
}

// MARK: - Product row

struct ProductRow: View {
    let product: Product

    var body: some View {
        HStack(spacing: 12) {
            ProductThumb(imageURL: product.imageURL, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !product.code.isEmpty {
                    Text(product.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !product.sku.isEmpty {
                    Text(product.sku)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("سعر البيع")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Formatters.number(product.price, minFraction: 2))
                    .font(.subheadline.bold())
                Text("الكمية: \(Formatters.number(product.qty, maxFraction: 3))")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(product.qty > 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(product.qty > 0 ? Color.green : Color.red)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Product form

struct ProductFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let product: Product?

    @State private var name: String
    @State private var code: String
    @State private var qty: String
    @State private var price: String
    @State private var imageURL: String
    @State private var sku: String
    @State private var cost: String

    init(product: Product?, prefillCode: String = "") {
        self.product = product
        _name = State(initialValue: product?.name ?? "")
        _code = State(initialValue: product?.code ?? prefillCode)
        _qty = State(
            initialValue: product.map { Formatters.number($0.qty, minFraction: 0, maxFraction: 3, grouping: false) } ?? "1"
        )
        _imageURL = State(initialValue: product?.imageURL ?? "")
        _sku = State(initialValue: product?.sku ?? "")
        _cost = State(
            initialValue: product.map { Formatters.number($0.cost, minFraction: 0, maxFraction: 4, grouping: false) } ?? ""
        )
        _price = State(
            initialValue: product.map { Formatters.number($0.price, minFraction: 0, maxFraction: 4, grouping: false) } ?? ""
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("بيانات المنتج") {
                    TextField("اسم المنتج", text: $name)
                    TextField("الباركود", text: $code)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("المرجع الداخلي (SKU)", text: $sku)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("الصورة") {
                    if !imageURL.trimmed.isEmpty {
                        HStack {
                            Spacer()
                            ProductThumb(imageURL: imageURL, size: 200)
                            Spacer()
                        }
                    }
                    TextField("رابط الصورة (اختياري)", text: $imageURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("المخزون والسعر") {
                    HStack {
                        Text("الكمية")
                        Spacer()
                        TextField("0", text: $qty)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("سعر البيع")
                        Spacer()
                        TextField("0", text: $price)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("التكلفة")
                        Spacer()
                        TextField("0", text: $cost)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle(product == nil ? "منتج جديد" : "تعديل المنتج")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") { save() }
                        .disabled(name.trimmed.isEmpty && code.trimmed.isEmpty)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func save() {
        let quantity = qty.parsedDouble ?? 0
        let unitPrice = price.parsedDouble ?? 0
        let costValue = cost.parsedDouble ?? 0
        let trimmedName = name.trimmed
        let trimmedCode = code.trimmed

        if let product {
            product.name = trimmedName.isEmpty ? trimmedCode : trimmedName
            product.code = trimmedCode
            product.qty = quantity
            product.price = unitPrice
            product.imageURL = imageURL.trimmed
            product.sku = sku.trimmed
            product.cost = costValue
            product.updatedAt = Date()
        } else {
            let newProduct = Product(
                name: trimmedName.isEmpty ? trimmedCode : trimmedName,
                code: trimmedCode,
                qty: quantity,
                price: unitPrice
            )
            newProduct.imageURL = imageURL.trimmed
            newProduct.sku = sku.trimmed
            newProduct.cost = costValue
            modelContext.insert(newProduct)
        }

        try? modelContext.save()
        AutoSync.request(modelContext)
        dismiss()
    }
}
