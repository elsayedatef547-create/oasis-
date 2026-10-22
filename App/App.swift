import SwiftUI
import SwiftData
import UIKit

@main
struct InvoiceScannerApp: App {
    let sharedModelContainer: ModelContainer
    private let storageFailed: Bool
    @State private var showStorageAlert = false
    @AppStorage(AppLogin.key) private var loggedIn = false

    init() {
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        AppSettings.migrateModelIfNeeded()

        let schema = Schema([Invoice.self, InvoiceItem.self, Product.self, ArchivedInvoice.self, ProductAlias.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        var failed = false
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            failed = true
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                container = try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
        sharedModelContainer = container
        storageFailed = failed
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if loggedIn {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
                .environment(\.layoutDirection, .rightToLeft)
                .onAppear { showStorageAlert = storageFailed }
                .alert("تعذّر فتح قاعدة البيانات", isPresented: $showStorageAlert) {
                    Button("حسناً", role: .cancel) {}
                } message: {
                    Text("التطبيق شغّال بقاعدة مؤقتة، يعني أي فاتورة أو تعديل هيضيع لما تقفل التطبيق. حدّث التطبيق أو أعد تثبيته، وزامن المخزون مع الشيت.")
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
