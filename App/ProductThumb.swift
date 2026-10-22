import SwiftUI
import UIKit

/// تحميل صور المنتجات مع كاش في الذاكرة وعلى الجهاز (عشان القوائم الطويلة متعيدش التحميل).
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        cache.countLimit = 800
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let original = UIImage(data: data) else { return nil }
            let image = ImageCache.downsample(original, maxSide: 700)
            cache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            return nil
        }
    }

    private static func downsample(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// صورة المنتج (من رابط الشيت) بحجم ثابت، مع أيقونة بديلة لو مفيش صورة.
struct ProductThumb: View {
    let imageURL: String?
    var size: CGFloat = 48

    @State private var image: UIImage?
    @State private var failed = false

    private var url: URL? { imageURL?.firstImageURL }

    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if url == nil {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        failed = false
        guard let url else {
            image = nil
            return
        }
        if let hit = ImageCache.shared.cached(url) {
            image = hit
            return
        }
        image = nil
        let loaded = await ImageCache.shared.load(url)
        if Task.isCancelled { return }
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }
}
