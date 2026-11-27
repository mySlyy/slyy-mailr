import Foundation
#if canImport(Darwin)
import Darwin
private let sysRead = Darwin.read
private let sysWrite = Darwin.write
private let sysClose = Darwin.close
private let sysConnect = Darwin.connect
private let streamType = SOCK_STREAM
#elseif canImport(Glibc)
import Glibc
private let sysRead = Glibc.read
private let sysWrite = Glibc.write
private let sysClose = Glibc.close
private let sysConnect = Glibc.connect
private let streamType = Int32(SOCK_STREAM.rawValue)
#endif

/// A local Unix-domain socket (Slyy Haven's `haven.sock`). Same code on macOS, iOS and Linux.
public final class UnixSocketStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "slyy.unix.write")
    private let lock = NSLock()
    private var closed = false
    public var readTimeout: TimeInterval = 300

    private init(fd: Int32) {
        self.fd = fd
    }

    public static func connect(path: String) throws -> UnixSocketStream {
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw TransportError.connectionFailed("socket path too long") }
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw TransportError.connectionFailed("socket() failed") }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysConnect(fd, $0, len) }
        }
        guard rc == 0 else {
            _ = sysClose(fd)
            throw TransportError.connectionFailed("nothing listening at \(path)")
        }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return UnixSocketStream(fd: fd)
    }

    public func read(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let timeoutMs = Int32(min(readTimeout * 1000, Double(Int32.max)))
            DispatchQueue.global().async { [fd] in
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, timeoutMs)
                if ready == 0 { return cont.resume(throwing: TransportError.timeout) }
                if ready < 0 { return cont.resume(throwing: TransportError.closed) }
                var buf = [UInt8](repeating: 0, count: maxLength)
                let n = sysRead(fd, &buf, maxLength)
                if n > 0 {
                    cont.resume(returning: Data(buf[0..<n]))
                } else {
                    cont.resume(throwing: TransportError.closed)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async { [fd] in
                let bytes = [UInt8](data)
                var offset = 0
                while offset < bytes.count {
                    #if canImport(Darwin)
                    let n = bytes[offset...].withUnsafeBufferPointer { sysWrite(fd, $0.baseAddress, $0.count) }
                    #else
                    let n = bytes[offset...].withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                    #endif
                    if n <= 0 { return cont.resume(throwing: TransportError.closed) }
                    offset += n
                }
                cont.resume()
            }
        }
    }

    public func startTLS() async throws {
        throw TransportError.tlsUnavailable
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, Int32(SHUT_RDWR))
        _ = sysClose(fd)
    }
}
