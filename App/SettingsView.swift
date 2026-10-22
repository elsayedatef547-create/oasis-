import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage(AppSettings.modelKey) private var geminiModel = AppSettings.defaultModel
    @AppStorage(AppSettings.languageKey) private var invoiceLanguage = InvoiceLanguage.both.rawValue
    @AppStorage(AppSettings.preciseKey) private var precise = true
    @AppStorage(AppLogin.key) private var loggedIn = false

    @State private var apiKey = ""
    @State private var showKey = false
    @State private var hasStoredKey = false
    @State private var statusMessage = ""
    @State private var statusIsError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if showKey {
                                TextField("مفتاح Gemini API", text: $apiKey)
                            } else {
                                SecureField("مفتاح Gemini API", text: $apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)

                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        saveKey()
                    } label: {
                        Label("حفظ المفتاح", systemImage: "key.fill")
                    }
                    .disabled(apiKey.trimmed.isEmpty)

                    if hasStoredKey {
                        Button(role: .destructive) {
                            deleteKey()
                        } label: {
                            Label("حذف المفتاح", systemImage: "trash")
                        }
                    }

                    if !statusMessage.isEmpty {
                        Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? Color.red : Color.green)
                    }

                    if let url = URL(string: "https://aistudio.google.com/apikey") {
                        Link(destination: url) {
                            Label("الحصول على مفتاح من Google AI Studio", systemImage: "arrow.up.right.square")
                                .font(.footnote)
                        }
                    }
                } header: {
                    Text("مفتاح Gemini API")
                } footer: {
                    Text("يُحفظ المفتاح بشكل آمن في Keychain على جهازك فقط.")
                }

                Section {
                    TextField("اسم النموذج", text: $geminiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Menu {
                        ForEach(AppSettings.modelPresets, id: \.self) { preset in
                            Button(preset) {
                                geminiModel = preset
                            }
                        }
                    } label: {
                        Label("اختيار نموذج مقترح", systemImage: "cpu")
                    }
                } header: {
                    Text("نموذج Gemini")
                } footer: {
                    Text("النموذج الحالي: \(geminiModel.trimmed.isEmpty ? AppSettings.defaultModel : geminiModel.trimmed)")
                }

                Section {
                    Picker("لغة الفاتورة", selection: $invoiceLanguage) {
                        ForEach(InvoiceLanguage.allCases) { lang in
                            Text(lang.title).tag(lang.rawValue)
                        }
                    }
                    Toggle("قراءة بدقة أعلى (مناسب لخط اليد)", isOn: $precise)
                } header: {
                    Text("قراءة الفاتورة")
                } footer: {
                    Text(precise
                         ? "بيستخدم النموذج المختار فوق."
                         : "بيستخدم النموذج الخفيف (\(AppSettings.liteModel)) للسرعة.")
                }

                SheetSyncSection()

                BackupSection()

                Section {
                    Button(role: .destructive) {
                        loggedIn = false
                    } label: {
                        Label("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section("حول التطبيق") {
                    HStack {
                        Text("الإصدار")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("الإعدادات")
            .onAppear {
                if let stored = KeychainHelper.readAPIKey(), !stored.isEmpty {
                    apiKey = stored
                    hasStoredKey = true
                } else {
                    hasStoredKey = false
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func saveKey() {
        let trimmed = apiKey.trimmed
        if KeychainHelper.saveAPIKey(trimmed) {
            apiKey = trimmed
            hasStoredKey = true
            statusIsError = false
            statusMessage = "تم حفظ المفتاح بنجاح."
        } else {
            statusIsError = true
            statusMessage = "تعذّر حفظ المفتاح في Keychain."
        }
    }

    private func deleteKey() {
        if KeychainHelper.deleteAPIKey() {
            apiKey = ""
            hasStoredKey = false
            statusIsError = false
            statusMessage = "تم حذف المفتاح."
        } else {
            statusIsError = true
            statusMessage = "تعذّر حذف المفتاح."
        }
    }
}
