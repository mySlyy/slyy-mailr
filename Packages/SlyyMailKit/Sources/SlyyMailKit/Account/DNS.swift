import Foundation
#if canImport(dnssd)
import dnssd
#endif

/// MX lookups through the system resolver (Apple platforms). Elsewhere: none.
public enum DNS {
    public static func mxHosts(for domain: String) async -> [String] {
        #if canImport(dnssd)
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: queryMX(domain)) }
        }
        #else
        return []
        #endif
    }

    /// Parses MX RDATA: 16-bit preference, then an uncompressed domain name.
    static func parseMX(_ bytes: [UInt8]) -> (Int, String)? {
        guard bytes.count >= 3 else { return nil }
        let pref = Int(bytes[0]) << 8 | Int(bytes[1])
        var labels: [String] = []
        var i = 2
        while i < bytes.count {
            let len = Int(bytes[i])
            if len == 0 { break }
            if len & 0xC0 != 0 { return nil } // compression pointer: not expected here
            i += 1
            guard i + len <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[i..<(i + len)], as: UTF8.self))
            i += len
        }
        guard !labels.isEmpty else { return nil }
        return (pref, labels.joined(separator: "."))
    }

    #if canImport(dnssd)
    private final class Box {
        var records: [(Int, String)] = []
        var moreComing = true
    }

    static func queryMX(_ domain: String) -> [String] {
        var ref: DNSServiceRef?
        let box = Box()
        let context = Unmanaged.passUnretained(box).toOpaque()
        let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, _, _, rdlen, rdata, _, ctx in
            guard let ctx else { return }
            let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
            box.moreComing = flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
            guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let rdata else { return }
            let bytes = [UInt8](UnsafeRawBufferPointer(start: rdata, count: Int(rdlen)))
            if let mx = DNS.parseMX(bytes) { box.records.append(mx) }
        }
        let err = DNSServiceQueryRecord(&ref, 0, 0, domain, UInt16(kDNSServiceType_MX), UInt16(kDNSServiceClass_IN), callback, context)
        guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return [] }
        defer { DNSServiceRefDeallocate(ref) }
        var pfd = pollfd(fd: DNSServiceRefSockFD(ref), events: Int16(POLLIN), revents: 0)
        while poll(&pfd, 1, 5000) > 0 {
            guard DNSServiceProcessResult(ref) == DNSServiceErrorType(kDNSServiceErr_NoError) else { break }
            if !box.moreComing { break }
        }
        return box.records.sorted { $0.0 < $1.0 }.map { $0.1.hasSuffix(".") ? String($0.1.dropLast()) : $0.1 }
    }
    #endif
}
