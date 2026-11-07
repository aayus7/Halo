import UIKit

enum ArtworkLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for track: Track) async -> UIImage? {
        let key = track.id as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var image: UIImage?
        if track.isLocal {
            let file = Paths.artworkFile(for: track.id)
            if let data = try? Data(contentsOf: file) {
                image = UIImage(data: data)
            }
        } else if let url = track.artworkURL {
            if let (data, _) = try? await AddonClient.session.data(from: url) {
                image = UIImage(data: data)
            }
        }
        if let image {
            let prepared = await image.byPreparingForDisplay() ?? image
            cache.setObject(prepared, forKey: key)
            return prepared
        }
        return nil
    }
}
