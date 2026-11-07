import UIKit

enum ArtworkLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// Cover for a track. With `hiRes`, Apple's catalog cover is preferred for streamed tracks
    /// (and for local files without embedded art).
    static func image(for track: Track, hiRes: Bool = true, size: Int = 1000) async -> UIImage? {
        let key = "\(track.id)|\(hiRes)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var image: UIImage?
        if track.isLocal, let data = try? Data(contentsOf: Paths.artworkFile(for: track.id)) {
            image = UIImage(data: data)
        }
        if image == nil, hiRes, let url = await ArtworkService.shared.hiResURL(for: track, size: size) {
            image = await load(url)
        }
        if image == nil, let url = track.artworkURL {
            image = await load(url)
        }
        guard let image else { return nil }
        let prepared = await image.byPreparingForDisplay() ?? image
        cache.setObject(prepared, forKey: key)
        return prepared
    }

    static func image(at url: URL?) async -> UIImage? {
        guard let url else { return nil }
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = await load(url) else { return nil }
        let prepared = await image.byPreparingForDisplay() ?? image
        cache.setObject(prepared, forKey: key)
        return prepared
    }

    private static func load(_ url: URL) async -> UIImage? {
        if url.isFileURL { return UIImage(contentsOfFile: url.path) }
        guard let (data, response) = try? await session.data(from: url),
              ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
        return UIImage(data: data)
    }
}
