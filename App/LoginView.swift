import SwiftUI

/// شاشة الدخول قبل فتح التطبيق. بتفضل مسجّل دخول على الجهاز لحد ما تعمل «تسجيل الخروج» من الإعدادات.
enum AppLogin {
    static let username = "01012"
    static let password = "01012"
    static let key = "app_logged_in"
}

struct LoginView: View {
    @AppStorage(AppLogin.key) private var loggedIn = false

    @State private var username = ""
    @State private var password = ""
    @State private var showError = false
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .padding(.top, 60)

                Text("OASIS")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.indigo)

                VStack(spacing: 12) {
                    TextField("اسم المستخدم", text: $username)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focused, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    SecureField("الرقم السري", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { signIn() }
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    if showError {
                        Label("اسم المستخدم أو الرقم السري غير صحيح", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        signIn()
                    } label: {
                        Text("دخول")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 28)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func signIn() {
        let user = username.normalizedDigits.trimmed
        let pass = password.normalizedDigits.trimmed
        if user == AppLogin.username && pass == AppLogin.password {
            showError = false
            loggedIn = true
        } else {
            showError = true
            password = ""
        }
    }
}
