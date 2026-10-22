import SwiftUI
import SwiftData

// MARK: - Preparation list (tab)

struct PreparationView: View {
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    private var preparing: [Invoice] {
        invoices.filter { $0.status == InvoiceStatus.preparing && !$0.isSupply }
    }

    private var done: [Invoice] {
        invoices.filter { $0.status == InvoiceStatus.done && !$0.isSupply }
    }

    var body: some View {
        NavigationStack {
            Group {
                if preparing.isEmpty && done.isEmpty {
                    ContentUnavailableView(
                        "لا توجد فواتير قيد التجهيز",
                        systemImage: "checklist",
                        description: Text("افتح فاتورة واضغط «تجهيز» لتظهر هنا.")
                    )
                } else {
                    List {
                        if !preparing.isEmpty {
                            Section("قيد التجهيز") {
                                ForEach(preparing) { invoice in
                                    NavigationLink {
                                        PreparationDetailView(invoice: invoice)
                                    } label: {
                                        PreparationRow(invoice: invoice)
                                    }
                                }
                            }
                        }
                        if !done.isEmpty {
                            Section("تم التجهيز") {
                                ForEach(done) { invoice in
                                    NavigationLink {
                                        PreparationDetailView(invoice: invoice)
                                    } label: {
                                        PreparationRow(invoice: invoice)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("التجهيز")
        }
    }
}

struct PreparationRow: View {
    let invoice: Invoice

    private var preparedCount: Int {
        invoice.items.filter { $0.prepared }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((invoice.status == InvoiceStatus.done ? Color.green : Color.indigo).opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: invoice.status == InvoiceStatus.done ? "checkmark" : "checklist")
                    .foregroundStyle(invoice.status == InvoiceStatus.done ? .green : .indigo)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(invoice.title)
                    .font(.headline)
                Text("جُهّز \(preparedCount) من \(invoice.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preparation detail

struct PreparationDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var invoice: Invoice
    @Query private var products: [Product]

    @State private var shareItem: ShareItem?
    @State private var alertMessage = ""
    @State private var showAlert = false

    private var sortedItems: [InvoiceItem] {
        invoice.items.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var preparedItems: [InvoiceItem] {
        sortedItems.filter { $0.prepared }
    }

    private var isFinished: Bool {
        invoice.status == InvoiceStatus.done
    }

    var body: some View {
        let matcher = StockMatcher(products: products)
        return List {
            Section {
                ProgressView(value: Double(preparedItems.count), total: Double(max(sortedItems.count, 1)))
                    .tint(.indigo)
                Text("جُهّز \(preparedItems.count) من \(sortedItems.count)")
                    .font(.subheadline.weight(.semibold))
            }

            Section("الأصناف") {
                ForEach(sortedItems) { item in
                    let info = matcher.info(for: item)
                    Button {
                        // لو الفاتورة منتهية وعدّلت صنف، بترجع تلقائيًا لـ «قيد التجهيز»
                        if isFinished { invoice.status = InvoiceStatus.preparing }
                        item.prepared.toggle()
                        if item.prepared {
                            InventoryService.deduct(item, products: products)
                        } else {
                            InventoryService.restore(item, products: products)
                        }
                        try? modelContext.save()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.prepared ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(item.prepared ? Color.green : Color.secondary)

                            ProductThumb(imageURL: info.product?.imageURL, size: 56)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name.isEmpty ? "صنف بدون اسم" : item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                    .strikethrough(item.prepared)
                                if !item.code.isEmpty {
                                    Text(item.code)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text("المطلوب: \(Formatters.number(item.qty, maxFraction: 3))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if item.prepared && item.stockDeducted > 0 {
                                    Text("اتخصم من المخزون: \(Formatters.number(item.stockDeducted, maxFraction: 3))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.indigo)
                                } else {
                                    StockBadge(info: info)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                if isFinished {
                    Menu {
                        Button {
                            sharePDF(items: preparedItems.isEmpty ? sortedItems : preparedItems)
                        } label: {
                            Label("الأصناف المجهّزة فقط", systemImage: "checkmark.circle")
                        }
                        Button {
                            sharePDF(items: sortedItems)
                        } label: {
                            Label("كل أصناف الفاتورة", systemImage: "list.bullet")
                        }
                    } label: {
                        Label("إنشاء فاتورة PDF للمشاركة", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        invoice.status = InvoiceStatus.preparing
                        try? modelContext.save()
                    } label: {
                        Label("إعادة فتح التجهيز", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        finish()
                    } label: {
                        Label("إنهاء التجهيز", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(preparedItems.isEmpty)
                }
            }
        }
        .navigationTitle(invoice.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("تنبيه", isPresented: $showAlert) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func finish() {
        invoice.status = InvoiceStatus.done
        try? modelContext.save()
        let matcher = StockMatcher(products: products)
        InvoiceArchive.save(
            invoice,
            items: preparedItems.isEmpty ? sortedItems : preparedItems,
            salePrice: { matcher.salePrice(for: $0) },
            in: modelContext
        )
    }

    private func sharePDF(items: [InvoiceItem]) {
        let matcher = StockMatcher(products: products)
        do {
            let url = try PDFGenerator.writeTemporaryFile(
                for: invoice,
                salePrice: { matcher.salePrice(for: $0) },
                items: items
            )
            InvoiceArchive.save(invoice, items: items, salePrice: { matcher.salePrice(for: $0) }, in: modelContext)
            shareItem = ShareItem(url: url)
        } catch {
            alertMessage = "تعذّر إنشاء ملف PDF: \(error.localizedDescription)"
            showAlert = true
        }
    }
}
