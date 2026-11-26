#if !canImport(Darwin)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Linux: plaintext TCP only. Used for running the core library's tests against local servers.
final class POSIXByteStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "slyy.posix.stream")
    private var closed = false

    private init(fd: Int32) {
        self.fd = fd
    }

    static func connect(host: String, port: Int) async throws -> POSIXByteStream {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
                    cont.resume(throwing: TransportError.connectionFailed("cannot resolve \(host)"))
                    return
                }
                defer { freeaddrinfo(res) }
                var ai: UnsafeMutablePointer<addrinfo>? = first
                while let a = ai {
                    let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
                    if fd >= 0 {
                        if Glibc.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                            cont.resume(returning: POSIXByteStream(fd: fd))
                            return
                        }
                        Glibc.close(fd)
                    }
                    ai = a.pointee.ai_next
                }
                cont.resume(throwing: TransportError.connectionFailed("cannot connect to \(host):\(port)"))
            }
        }
    }

    func read(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { [fd] in
                var buf = [UInt8](repeating: 0, count: maxLength)
                let n = Glibc.read(fd, &buf, maxLength)
                if n > 0 {
                    cont.resume(returning: Data(buf[0..<n]))
                } else {
                    cont.resume(throwing: TransportError.closed)
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [fd] in
                var offset = 0
                let bytes = [UInt8](data)
                while offset < bytes.count {
                    let n = bytes[offset...].withUnsafeBufferPointer { Glibc.write(fd, $0.baseAddress, $0.count) }
                    if n <= 0 {
                        cont.resume(throwing: TransportError.closed)
                        return
                    }
                    offset += n
                }
                cont.resume()
            }
        }
    }

    func startTLS() async throws {
        throw TransportError.tlsUnavailable
    }

    func close() {
        guard !closed else { return }
        closed = true
        shutdown(fd, Int32(SHUT_RDWR))
        Glibc.close(fd)
    }
}
#endif
