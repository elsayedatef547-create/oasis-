import SwiftUI
import SwiftData
import AVFoundation
import UIKit

// MARK: - Scanner screen

struct ScannerView: View {
    @Query private var products: [Product]

    @State private var scannedCode: String?
    @State private var torchOn = false
    @State private var isRunning = false
    @State private var cameraError: String?
    @State private var showAddProduct = false

    /// كل المنتجات اللي ليها نفس الباركود أو الـ SKU (ممكن أكتر من منتج بنفس الباركود)
    private var matchedProducts: [Product] {
        guard let code = scannedCode else { return [] }
        let key = code.codeKey
        if key.isEmpty { return [] }
        return products.filter { $0.code.codeKey == key || (!$0.sku.isEmpty && $0.sku.codeKey == key) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let cameraError {
                errorView(message: cameraError)
            } else {
                BarcodeScannerRepresentable(
                    isRunning: isRunning,
                    torchOn: torchOn,
                    onScan: { code in
                        scannedCode = code
                    },
                    onError: { message in
                        cameraError = message
                    }
                )
                .ignoresSafeArea()

                overlayContent
            }
        }
        .onAppear {
            isRunning = true
        }
        .onDisappear {
            isRunning = false
            torchOn = false
        }
        .onChange(of: showAddProduct) { _, isShown in
            isRunning = !isShown
        }
        .sheet(isPresented: $showAddProduct) {
            ProductFormView(product: nil, prefillCode: scannedCode ?? "")
        }
    }

    // MARK: Overlay

    private var overlayContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ماسح الباركود")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
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
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [14, 8]))
                        .frame(width: 290, height: 180)
                    Rectangle()
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 250, height: 2)
                }
                Text("وجّه الكاميرا نحو الباركود")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            Spacer()

            resultCard
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if let code = scannedCode {
            VStack(alignment: .leading, spacing: 12) {
                if !matchedProducts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(matchedProducts) { product in
                                ScannedProductCard(product: product)
                                if product.persistentModelID != matchedProducts.last?.persistentModelID {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("المنتج غير موجود في المخزون", systemImage: "questionmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("الكود: \(code)")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    if matchedProducts.isEmpty {
                        Button {
                            showAddProduct = true
                        } label: {
                            Label("إضافة منتج", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }

                    Button {
                        scannedCode = nil
                    } label: {
                        Label("مسح جديد", systemImage: "barcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.8))
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("فتح الإعدادات")
                    .padding(.horizontal, 20)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
    }
}

private struct ScannedProductCard: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var product: Product
    @FocusState private var qtyFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductThumb(imageURL: product.imageURL, size: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(product.name)
                    .font(.headline)
                Text("الكود: \(product.code)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !product.sku.isEmpty {
                    Text("SKU: \(product.sku)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("سعر البيع: \(Formatters.number(product.price, minFraction: 2))")
                    .font(.subheadline)
                HStack(spacing: 8) {
                    Text("الكمية:")
                        .font(.subheadline.weight(.semibold))
                    TextField("0", value: $product.qty, format: .number.locale(Locale(identifier: "en_US")).grouping(.never))
                        .keyboardType(.decimalPad)
                        .focused($qtyFocused)
                        .multilineTextAlignment(.center)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 80)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    if qtyFocused {
                        Button("تم") { qtyFocused = false }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                    }
                    Spacer(minLength: 0)
                    Stepper("", value: $product.qty, in: 0...1_000_000, step: 1)
                        .labelsHidden()
                }

            }
        }
        .onChange(of: product.qty) { _, _ in
            product.updatedAt = Date()
            AutoSync.request(modelContext)
        }
    }
}

// MARK: - Camera preview view

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
            return AVCaptureVideoPreviewLayer()
        }
        return previewLayer
    }
}

// MARK: - UIViewRepresentable

struct BarcodeScannerRepresentable: UIViewRepresentable {
    let isRunning: Bool
    let torchOn: Bool
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.configure(previewView: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        context.coordinator.onScan = onScan
        context.coordinator.onError = onError
        context.coordinator.setTorch(torchOn)
        context.coordinator.setRunning(isRunning)
    }

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: (String) -> Void
        var onError: (String) -> Void

        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.invoicescanner.scanner.session")
        private var isConfigured = false
        private var desiredRunning = false
        private var lastValue: String?
        private var lastScanDate = Date.distantPast
        private let feedback = UINotificationFeedbackGenerator()

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
            super.init()
        }

        func configure(previewView: CameraPreviewView) {
            previewView.previewLayer.session = session

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                setupSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        self.setupSession()
                    } else {
                        self.report("تم رفض الوصول إلى الكاميرا. فعّل الإذن من الإعدادات لاستخدام الماسح.")
                    }
                }
            default:
                report("الوصول إلى الكاميرا غير مسموح. فعّل الإذن من الإعدادات لاستخدام الماسح.")
            }
        }

        private func report(_ message: String) {
            DispatchQueue.main.async { [weak self] in
                self?.onError(message)
            }
        }

        private func setupSession() {
            sessionQueue.async { [weak self] in
                guard let self, !self.isConfigured else { return }

                guard let device = AVCaptureDevice.default(for: .video) else {
                    self.report("الكاميرا غير متاحة على هذا الجهاز.")
                    return
                }

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureMetadataOutput()

                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }

                    guard self.session.canAddInput(input) else {
                        self.report("تعذّر تهيئة مدخل الكاميرا.")
                        return
                    }
                    self.session.addInput(input)

                    guard self.session.canAddOutput(output) else {
                        self.report("تعذّر تهيئة قارئ الباركود.")
                        return
                    }
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)

                    let wanted: [AVMetadataObject.ObjectType] = [
                        .ean13, .ean8, .upce, .code128, .code39, .code93,
                        .qr, .pdf417, .itf14, .interleaved2of5, .dataMatrix, .aztec
                    ]
                    output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }

                    self.isConfigured = true
                } catch {
                    self.report("تعذّر تشغيل الكاميرا: \(error.localizedDescription)")
                    return
                }

                if self.desiredRunning && !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }

        func setRunning(_ running: Bool) {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.desiredRunning = running
                if running {
                    if self.isConfigured && !self.session.isRunning {
                        self.session.startRunning()
                    }
                } else if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }

        func setTorch(_ on: Bool) {
            sessionQueue.async {
                guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
                let mode: AVCaptureDevice.TorchMode = on ? .on : .off
                guard device.torchMode != mode else { return }
                do {
                    try device.lockForConfiguration()
                    device.torchMode = mode
                    device.unlockForConfiguration()
                } catch {
                    return
                }
            }
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.desiredRunning = false
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                if let device = AVCaptureDevice.default(for: .video), device.hasTorch, device.torchMode != .off {
                    do {
                        try device.lockForConfiguration()
                        device.torchMode = .off
                        device.unlockForConfiguration()
                    } catch {
                        return
                    }
                }
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                let value = object.stringValue,
                !value.isEmpty
            else { return }

            let now = Date()
            if value == lastValue && now.timeIntervalSince(lastScanDate) < 1.5 {
                return
            }
            lastValue = value
            lastScanDate = now

            feedback.notificationOccurred(.success)
            onScan(value)
        }
    }
}
