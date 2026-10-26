import Foundation
import Darwin

/// Minimal blocking TCP/UDP socket helpers (BSD sockets) used by the
/// handshake and the lane engine. Mirrors the Kotlin java.net.Socket usage.
/// All libc calls are Darwin.-prefixed to avoid instance-method shadowing.
final class TcpSocket {

    private var fd: Int32 = -1

    var isValid: Bool { fd >= 0 }

    /// TCP_NODELAY + keepalive, 5s connect timeout (Kotlin parity).
    static func connect(host: String, port: UInt16 = 53, connectTimeoutMs: Int32 = 5000) throws -> TcpSocket {
        guard var addr = ipFromString(host) else {
            throw EngineError.socket("bad host \(host)")
        }
        addr.sin_port = port.bigEndian
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw EngineError.socket("socket() failed") }

        // non-blocking for the timed connect
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            if errno == EINPROGRESS {
                var pollFd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                let pr = Darwin.poll(&pollFd, 1, connectTimeoutMs)
                if pr <= 0 {
                    Darwin.close(sock)
                    throw EngineError.socket("connect timeout to \(host):\(port)")
                }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
                if err != 0 {
                    Darwin.close(sock)
                    throw EngineError.socket("connect to \(host):\(port) failed errno \(err)")
                }
            } else {
                let e = errno
                Darwin.close(sock)
                throw EngineError.socket("connect to \(host):\(port) failed errno \(e)")
            }
        }
        _ = fcntl(sock, F_SETFL, flags) // restore blocking

        let s = TcpSocket()
        s.fd = sock
        s.applyOptions()
        return s
    }

    private func applyOptions() {
        var one: Int32 = 1
        _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Write watchdog (Kotlin parity): a resolver that stops reading must not
        // block the lane's transceiver thread inside send() forever. On Darwin
        // close() from another thread does NOT interrupt a blocked send, so the
        // timeout is the only reliable escape.
        var tv = timeval(tv_sec: 2, tv_usec: 500_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Read timeout for the lane reader watchdog (ms).
    func setRecvTimeout(ms: Int32) {
        var tv = timeval(tv_sec: time_t(ms / 1000), tv_usec: __darwin_suseconds_t((ms % 1000) * 1000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ data: [UInt8]) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            if n <= 0 { throw EngineError.socket("send failed errno \(errno)") }
            sent += n
        }
    }

    func receive(_ count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress!.advanced(by: got), count - got, 0)
            }
            if n == 0 { throw EngineError.socket("connection closed") }
            if n < 0 {
                if errno == EAGAIN { throw EngineError.socket("read timeout") }
                throw EngineError.socket("recv failed errno \(errno)")
            }
            got += n
        }
        return buf
    }

    /// Reads one length-prefixed DNS frame (2-byte BE length + payload).
    func readFrame() throws -> [UInt8] {
        let lenBuf = try receive(2)
        let len = (Int(lenBuf[0]) << 8) | Int(lenBuf[1])
        guard len > 0, len <= 65535 else { throw EngineError.socket("bad frame \(len)") }
        return try receive(len)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }

    static func ipFromString(_ s: String) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        let ok = s.withCString { cs in
            inet_pton(AF_INET, cs, &addr.sin_addr) == 1
        }
        return ok ? addr : nil
    }
}

/// One-shot UDP query (handshake fallback path).
enum UdpDns {
    static func query(host: String, query: [UInt8], timeoutMs: Int32 = 6000) throws -> [UInt8] {
        guard var addr = TcpSocket.ipFromString(host) else { throw EngineError.socket("bad host \(host)") }
        addr.sin_port = UInt16(53).bigEndian
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw EngineError.socket("udp socket failed") }
        defer { Darwin.close(sock) }
        var tv = timeval(tv_sec: time_t(timeoutMs / 1000), tv_usec: __darwin_suseconds_t((timeoutMs % 1000) * 1000))
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let sent = query.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(sock, raw.baseAddress!, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { throw EngineError.socket("udp send failed") }
        var buf = [UInt8](repeating: 0, count: 65536)
        let bufLen = buf.count
        let n = buf.withUnsafeMutableBytes { raw in
            Darwin.recv(sock, raw.baseAddress!, bufLen, 0)
        }
        guard n > 0 else { throw EngineError.socket("udp recv failed/timeout") }
        return Array(buf[0..<n])
    }
}
