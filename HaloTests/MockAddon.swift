import Foundation
@testable import Halo

/// Answers HTTP requests for fake addons, so tests run without the network.
final class MockAddonProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var json: Any
        var headers: [String: String] = [:]
    }

    /// host → handler(path after the token, query items) → reply
    nonisolated(unsafe) static var routes: [String: (String, [String: String]) -> Reply] = [:]
    nonisolated(unsafe) static var log: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return routes[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.routes[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // Drop the token segment: /TOKEN/search → /search
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.first == "tok" { parts.removeFirst() }
        let path = "/" + parts.joined(separator: "/")
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a })
        Self.log.append("\(host)\(path)?\(query.keys.sorted().map { "\($0)=\(query[$0]!)" }.joined(separator: "&"))")
        let reply = handler(path, query)
        let data = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func install() {
        AddonClient.session = AddonClient.makeSession(protocolClasses: [MockAddonProtocol.self])
        log = []
    }
}

enum Fixtures {
    static var tidoManifest: [String: Any] {
        let url = Bundle(for: MockAddonProtocol.self).url(forResource: "tido-manifest", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    /// A short sine-wave WAV written to the app's Music folder; its file URL stands in for a stream.
    static func toneFile(seconds: Double = 6) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("halo-test-tone.wav")
        let rate = 44100, channels = 2
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for i in 0..<frames {
            let v = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 8000)
            for _ in 0..<channels { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate))
        u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        header.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        try? (header + pcm).write(to: url)
        return url
    }

    /// What a Spotify import produces for a song.
    static let familyBusiness = Track(
        id: "spotify:4n8N7mBd4fJ3kZ", title: "Family Business", artist: "Kanye West",
        album: "The College Dropout", duration: 356.4, source: .catalog(service: "spotify", id: "4n8N7mBd4fJ3kZ"),
        isrc: "USDJ20400376")
}
