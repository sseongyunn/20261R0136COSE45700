import Foundation

private let networkSession: URLSession = {
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = 15
    sessionConfig.timeoutIntervalForResource = 20
    return URLSession(configuration: sessionConfig)
}()

private let imageCache = NSCache<NSString, UIImage>()
private let imageFetchQueue = DispatchQueue(label: "arkit.imageFetchQueue")
private var pendingImageRequests: [String: [(UIImage?) -> Void]] = [:]

func prefetchImagesIfNeeded(_ names: [String], completion: @escaping () -> Void) {
    let urls = names.compactMap { URL(string: $0) }.filter {
        $0.scheme == "http" || $0.scheme == "https"
    }

    guard !urls.isEmpty else {
        completion()
        return
    }

    let group = DispatchGroup()
    for url in urls {
        if imageCache.object(forKey: url.absoluteString as NSString) != nil {
            continue
        }
        group.enter()
        fetchNetworkImageIfNeeded(url) { _ in
            group.leave()
        }
    }

    group.notify(queue: .main) {
        completion()
    }
}

func fetchNetworkImageIfNeeded(_ url: URL, completion: @escaping (UIImage?) -> Void) {
    if let cached = imageCache.object(forKey: url.absoluteString as NSString) {
        completion(cached)
        return
    }
    let cacheKey = url.absoluteString
    var shouldStartRequest = false
    imageFetchQueue.sync {
        if pendingImageRequests[cacheKey] != nil {
            pendingImageRequests[cacheKey]?.append(completion)
        } else {
            pendingImageRequests[cacheKey] = [completion]
            shouldStartRequest = true
        }
    }
    if !shouldStartRequest {
        return
    }

    var request = URLRequest(url: url)
    request.cachePolicy = .useProtocolCachePolicy
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

    let task = networkSession.dataTask(with: request) { data, response, error in
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let httpURLString = http.url?.absoluteString ?? ""
            debugPrint("getImageByName: network non-2xx status \(http.statusCode) url \(httpURLString)")
        }

        if let error = error {
            let nsError = error as NSError
            debugPrint(
                "getImageByName: network load failed for \(url.absoluteString) " +
                "error: \(nsError.localizedDescription) " +
                "domain: \(nsError.domain) code: \(nsError.code) " +
                "userInfo: \(nsError.userInfo)"
            )
            let completions = imageFetchQueue.sync { pendingImageRequests.removeValue(forKey: cacheKey) } ?? []
            completions.forEach { $0(nil) }
            return
        }

        guard let data = data else {
            debugPrint("getImageByName: network returned no data for \(url.absoluteString)")
            let completions = imageFetchQueue.sync { pendingImageRequests.removeValue(forKey: cacheKey) } ?? []
            completions.forEach { $0(nil) }
            return
        }

        let img = UIImage(data: data)
        if img == nil {
            debugPrint("getImageByName: network data not decodable as image for \(url.absoluteString) (bytes: \(data.count))")
        } else {
            imageCache.setObject(img!, forKey: url.absoluteString as NSString)
        }
        let completions = imageFetchQueue.sync { pendingImageRequests.removeValue(forKey: cacheKey) } ?? []
        completions.forEach { $0(img) }
    }
    task.resume()
}

func getImageByName(_ name: String) -> UIImage? {
    if let img = UIImage(named: name) {
        return img
    }
    if let path = Bundle.main.path(forResource: SwiftArkitPlugin.registrar!.lookupKey(forAsset: name), ofType: nil) {
        let img = UIImage(named: path)
        if img == nil {
            debugPrint("getImageByName: failed to load asset image at path \(path) for \(name)")
        }
        return img
    }
    if let url = URL(string: name) {
        if let cached = imageCache.object(forKey: url.absoluteString as NSString) {
            return cached
        }
        debugPrint("getImageByName: network image not prefetched for \(name)")
        return nil
    }
    if let base64 = Data(base64Encoded: name, options: .ignoreUnknownCharacters) {
        let img = UIImage(data: base64)
        if img == nil {
            debugPrint("getImageByName: base64 data not decodable as image (bytes: \(base64.count))")
        }
        return img
    }
    debugPrint("getImageByName: failed to resolve image for \(name)")
    return nil
}
