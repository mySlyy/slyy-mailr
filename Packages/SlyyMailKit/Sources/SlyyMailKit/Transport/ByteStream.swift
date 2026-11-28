import Foundation

/// How a connection to a mail server is secured.
public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte (IMAP 993, SMTP 465).
    case tls
    /// Plain connect, then upgrade with STARTTLS before login (IMAP 143, SMTP 587). Login is refused if the upgrade fails.
    case startTLS
    /// No encryption. Only for local development servers.
    case plain
}

public struct ServerEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity

    public init(host: String, port: Int, security: ConnectionSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }
}

public enum TransportError: Error, LocalizedError, Equatable {
    /// A system networking error (socket not connected, connection reset or lost, broken pipe, network down,
    /// timeout) as a TransportError, so callers reconnect instead of showing the raw message. Others pass through.
    public static func wrap(_ error: Error) -> Error {
        if error is TransportError || error is CancellationError { return error }
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain {
            // ETIMEDOUT 60 (Darwin) / 110 (Linux); everything else at socket level means the connection is gone.
            return e.code == 60 || e.code == 110 ? TransportError.timeout : TransportError.closed
        }
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorTimedOut: return TransportError.timeout
            case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
                return TransportError.closed
            default: return error // e.g. certificate problems stay visible as such
            }
        }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error { 
            let mapped = wrap(underlying)
            if mapped is TransportError { return mapped }
        }
        return error
    }


    case connectionFailed(String)
    case closed
    case timeout
    case tlsUnavailable

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .closed: return "The connection to the server was lost. Please try again."
        case .timeout: return "The server did not answer in time."
        case .tlsUnavailable: return "TLS is not available on this platform."
        }
    }
}

/// A bidirectional byte stream to a server.
public protocol ByteStream: AnyObject, Sendable {
    /// Seconds a read may wait for data before throwing `TransportError.timeout`.
    var readTimeout: TimeInterval { get set }
    /// Returns at least one byte, or throws `TransportError.closed` at end of stream.
    func read(maxLength: Int) async throws -> Data
    func write(_ data: Data) async throws
    /// Upgrades the open connection to TLS (STARTTLS).
    func startTLS() async throws
    func close()
}

public enum Transport {
    /// Override for tests (e.g. an in-memory stream).
    nonisolated(unsafe) public static var factory: ((ServerEndpoint) async throws -> ByteStream)?

    public static func connect(_ endpoint: ServerEndpoint, timeout: TimeInterval = 30) async throws -> ByteStream {
        if let factory { return try await factory(endpoint) }
        #if canImport(Darwin)
        let s = StreamTaskByteStream(host: endpoint.host, port: endpoint.port, timeout: timeout)
        if endpoint.security == .tls { try await s.startTLS() }
        #else
        if endpoint.security == .tls { throw TransportError.tlsUnavailable }
        let s = try await POSIXByteStream.connect(host: endpoint.host, port: endpoint.port)
        #endif
        s.readTimeout = timeout
        return s
    }
}

/// Buffered reading of CRLF lines and fixed-size chunks (IMAP literals, SMTP replies).
public final class BufferedStream: @unchecked Sendable {
    public let stream: ByteStream
    private var buffer = Data()

    public init(_ stream: ByteStream) {
        self.stream = stream
    }

    /// Reads one line, without the trailing CRLF (or LF).
    public func readLine(limit: Int = 10 * 1024 * 1024) async throws -> Data {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<i]
                if line.last == 0x0D { line = line.dropLast() }
                buffer = Data(buffer[(i + 1)...])
                return Data(line)
            }
            if buffer.count > limit { throw TransportError.connectionFailed("line too long") }
            buffer.append(try await stream.read(maxLength: 64 * 1024))
        }
    }

    public func readExactly(_ count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await stream.read(maxLength: max(64 * 1024, count - buffer.count)))
        }
        let out = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return out
    }

    public func write(_ data: Data) async throws {
        try await stream.write(data)
    }

    public func write(_ string: String) async throws {
        try await stream.write(Data(string.utf8))
    }

    /// STARTTLS must only happen with an empty read buffer (no injected plaintext after the upgrade).
    public func startTLS() async throws {
        guard buffer.isEmpty else { throw TransportError.connectionFailed("unexpected data before TLS upgrade") }
        try await stream.startTLS()
    }

    public var readTimeout: TimeInterval {
        get { stream.readTimeout }
        set { stream.readTimeout = newValue }
    }

    public func close() {
        stream.close()
    }
}
