import Foundation

enum MediaRepository {
    static func imageData(from url: URL) async throws -> Data {
        try Task.checkCancellation()
        if url.isFileURL {
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            try Task.checkCancellation()
            return data
        }
        if url.scheme == "data" {
            let data = try await Task.detached(priority: .userInitiated) {
                let value = url.absoluteString
                guard value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else {
                    throw RepositoryError(message: "图片格式无法读取")
                }
                return data
            }.value
            try Task.checkCancellation()
            return data
        }
        let (data, response) = try await NetSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RepositoryError(message: "图片读取失败")
        }
        return data
    }

    static func upload(_ data: Data, to url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (payload, response) = try await NetSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: payload) as? JSONDict,
              let path = json.str("path") else { throw RepositoryError(message: "电脑端回了 HTTP \(code)") }
        return path
    }
}
