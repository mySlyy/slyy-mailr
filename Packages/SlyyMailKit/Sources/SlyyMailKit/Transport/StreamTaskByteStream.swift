#if canImport(Darwin)
import Foundation

/// Apple platforms: URLSessionStreamTask gives TCP + system TLS (trust store, ATS) and supports STARTTLS upgrades.
final class StreamTaskByteStream: ByteStream, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private let timeout: TimeInterval
    var readTimeout: TimeInterval = 60

    init(host: String, port: Int, timeout: TimeInterval) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600 // per-read timeouts handle stalls; IDLE must not be cut
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: cfg)
        task = session.streamTask(withHostName: host, port: port)
        self.timeout = timeout
        task.resume()
    }

    func read(maxLength: Int) async throws -> Data {
        let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: maxLength, timeout: readTimeout)
        if let data, !data.isEmpty { return data }
        if eof { throw TransportError.closed }
        throw TransportError.timeout
    }

    func write(_ data: Data) async throws {
        try await task.write(data, timeout: timeout)
    }

    func startTLS() async throws {
        task.startSecureConnection()
    }

    func close() {
        task.closeWrite()
        task.closeRead()
        task.cancel()
        session.invalidateAndCancel()
    }
}
#endif
