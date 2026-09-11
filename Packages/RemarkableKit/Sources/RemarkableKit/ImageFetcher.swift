import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads the images referenced by an article.
public struct ImageFetcher {
    public var session: URLSession
    /// Maximum number of images downloaded per article.
    public var maxCount: Int
    /// Images larger than this are skipped.
    public var maxBytesPerImage: Int
    public var maxConcurrent: Int

    public init(session: URLSession = ImageFetcher.makeSession(), maxCount: Int = 40, maxBytesPerImage: Int = 20_000_000, maxConcurrent: Int = 4) {
        self.session = session
        self.maxCount = maxCount
        self.maxBytesPerImage = maxBytesPerImage
        self.maxConcurrent = maxConcurrent
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = [
            "User-Agent": "SendToRemarkable/1.0 (NetNewsWire share extension)",
            "Accept": "image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8,*/*;q=0.5",
        ]
        return URLSession(configuration: configuration)
    }

    /// Fetches the given URLs. Failures are silently dropped from the result.
    public func fetch(_ urls: [URL], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [URL: Data] {
        let targets = Array(urls.prefix(maxCount))
        guard !targets.isEmpty else { return [:] }
        let total = targets.count
        var results: [URL: Data] = [:]
        var completed = 0

        await withTaskGroup(of: (URL, Data?).self) { group in
            var iterator = targets.makeIterator()
            var inFlight = 0

            func enqueue(_ url: URL) {
                group.addTask {
                    let data = await self.fetchOne(url)
                    return (url, data)
                }
            }

            while inFlight < maxConcurrent, let url = iterator.next() {
                enqueue(url)
                inFlight += 1
            }
            while let result = await group.next() {
                let (url, data) = result
                inFlight -= 1
                completed += 1
                if let data { results[url] = data }
                progress?(completed, total)
                if let next = iterator.next() {
                    enqueue(next)
                    inFlight += 1
                }
            }
        }
        return results
    }

    func fetchOne(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard !data.isEmpty, data.count <= maxBytesPerImage else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
