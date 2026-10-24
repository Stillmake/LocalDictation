import Foundation
import Network

/// Minimal loopback HTTP/1.1 server speaking the OpenAI `/v1/audio/transcriptions` dialect.
/// One request per connection; every response closes the connection.
final class HTTPServer: Sendable {
    private let listener: NWListener

    init(port: UInt16, transcriber: Transcriber) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task { await Self.serve(connection, transcriber: transcriber) }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    deinit { listener.cancel() }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct Response {
        var status = 200
        var contentType = "application/json"
        var body = Data()

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }

        static func error(_ message: String, status: Int) -> Response {
            .json(["error": ["message": message]], status: status)
        }
    }

    private static func serve(_ connection: NWConnection, transcriber: Transcriber) async {
        let response: Response
        do {
            response = try await route(try await read(connection), transcriber: transcriber)
        } catch {
            response = .error(error.localizedDescription, status: 400)
        }
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        let head = "HTTP/1.1 \(response.status) \(reason)\r\n"
            + "Content-Type: \(response.contentType)\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func route(_ request: Request, transcriber: Transcriber) async throws -> Response {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return if let name = await transcriber.modelName {
                .json(["status": "ready", "model": name])
            } else {
                .json(["status": "loading"], status: 503)
            }

        case ("GET", "/v1/models"):
            let data = await transcriber.modelName.map { [["id": $0, "object": "model", "owned_by": "local"]] } ?? []
            return .json(["object": "list", "data": data])

        case ("POST", "/v1/audio/transcriptions"):
            guard let contentType = request.headers["content-type"],
                  let boundary = contentType.split(separator: ";")
                      .map({ $0.trimmingCharacters(in: .whitespaces) })
                      .first(where: { $0.hasPrefix("boundary=") })?
                      .dropFirst("boundary=".count)
                      .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            else { return .error("expected multipart/form-data", status: 400) }

            let parts = multipart(request.body, boundary: boundary)
            guard let file = parts["file"] else { return .error("missing `file` field", status: 400) }
            let field = { (name: String) in parts[name].flatMap { String(data: $0.data, encoding: .utf8) } }
            let format = field("response_format") ?? "json"
            guard ["json", "text", "verbose_json"].contains(format) else {
                return .error("unsupported response_format: \(format)", status: 400)
            }

            let fileExtension = (file.filename as NSString?)?.pathExtension ?? ""
            let audioURL = URL.temporaryDirectory.appending(path: UUID().uuidString)
                .appendingPathExtension(fileExtension.isEmpty ? "wav" : fileExtension)
            try file.data.write(to: audioURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let output: Qwen3ASRModel.Output
            do {
                output = try await transcriber.transcribe(
                    audioURL,
                    language: field("language"),
                    // OpenAI's `prompt` field carries comma-separated hotwords, e.g. "Kubernetes, SwiftUI, 张三".
                    hotwords: field("prompt")
                )
            } catch is Transcriber.NotReady {
                return .error("model is still loading", status: 503)
            }

            switch format {
            case "text":
                return Response(contentType: "text/plain; charset=utf-8", body: Data(output.text.utf8))
            case "verbose_json":
                return .json(["text": output.text, "language": output.language as Any? ?? NSNull()])
            default:
                return .json(["text": output.text])
            }

        default:
            return .error("not found", status: 404)
        }
    }

    private static func read(_ connection: NWConnection) async throws -> Request {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            buffer += try await receive(connection)
            headerEnd = buffer.range(of: separator)
        }

        let lines = String(decoding: buffer[..<headerEnd!.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { throw URLError(.badServerResponse) }
        let headers = Dictionary(
            lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            },
            uniquingKeysWith: { _, last in last }
        )

        // curl sends `Expect: 100-continue` for uploads over 1 MB and stalls a second without this.
        if headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        var body = buffer[headerEnd!.upperBound...]
        while body.count < length {
            body += try await receive(connection)
        }

        let target = String(requestLine[1])
        return Request(
            method: String(requestLine[0]),
            path: String(target.prefix { $0 != "?" }),
            headers: headers,
            body: Data(body.prefix(length))
        )
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    assert(isComplete)
                    continuation.resume(throwing: URLError(.networkConnectionLost))
                }
            }
        }
    }

    private static func multipart(_ body: Data, boundary: String) -> [String: (filename: String?, data: Data)] {
        let delimiter = Data("\r\n--\(boundary)".utf8)
        let headerSeparator = Data("\r\n\r\n".utf8)
        // Prepend CRLF so the first delimiter matches the same pattern as the rest.
        let body = Data("\r\n".utf8) + body
        var parts: [String: (filename: String?, data: Data)] = [:]
        var cursor = body.startIndex

        while let start = body.range(of: delimiter, in: cursor..<body.endIndex) {
            let partStart = start.upperBound + 2  // skip CRLF after the delimiter (or `--` at the end)
            guard partStart <= body.endIndex,
                  body[start.upperBound..<min(partStart, body.endIndex)] != Data("--".utf8),
                  let next = body.range(of: delimiter, in: partStart..<body.endIndex),
                  let split = body.range(of: headerSeparator, in: partStart..<next.lowerBound)
            else { break }

            let disposition = String(decoding: body[partStart..<split.lowerBound], as: UTF8.self)
            let attribute = { (key: String) -> String? in
                disposition.range(of: "\(key)=\"").flatMap { open in
                    disposition[open.upperBound...].firstIndex(of: "\"").map { String(disposition[open.upperBound..<$0]) }
                }
            }
            if let name = attribute(" name") ?? attribute(";name") {
                parts[name] = (attribute("filename"), Data(body[split.upperBound..<next.lowerBound]))
            }
            cursor = next.lowerBound
        }
        return parts
    }
}
