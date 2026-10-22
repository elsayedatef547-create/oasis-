import SwiftUI
import AVFoundation

/// شاشة مسح باركود للبحث في المخزون. تُرجع الكود عبر onFound ثم تُغلق نفسها.
struct BarcodeSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var torchOn = false
    @State private var errorMessage: String?

    let onFound: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                BarcodeScannerRepresentable(
                    isRunning: true,
                    torchOn: torchOn,
                    onScan: { code in
                        onFound(code)
                        dismiss()
                    },
                    onError: { message in
                        errorMessage = message
                    }
                )
                .ignoresSafeArea()

                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [14, 8]))
                    .frame(width: 290, height: 180)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    Button {
                        torchOn.toggle()
                    } label: {
                        Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                }
                .padding()
                Spacer()
                Text("وجّه الكاميرا نحو باركود المنتج")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 40)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
