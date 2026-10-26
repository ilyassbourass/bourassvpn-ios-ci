import Foundation
import CryptoKit
import CZstd

/// Crypto + compression primitives. AES-GCM via CryptoKit, zstd via the
/// vendored C library — the same stack the Android engine uses
/// (javax.crypto AES/GCM + zstd-jni level 1).
public enum Crypto {

    public static func sha256Hex(_ input: String) -> String {
        let d = SHA256.hash(data: Data(input.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(data), using: SymmetricKey(data: Data(key)))
        return Array(mac)
    }

    /// 0xf1 + iv(12) + ciphertext+tag(16) — the FastDNS envelope.
    public static func gcmSeal(key: [UInt8], iv: [UInt8], plaintext: [UInt8]) throws -> [UInt8] {
        let sealed = try AES.GCM.seal(Data(plaintext), using: SymmetricKey(data: Data(key)), nonce: AES.GCM.Nonce(data: Data(iv)))
        guard let ct = sealed.combined else { throw EngineError.crypto("seal failed") }
        // combined = nonce(12) + ct + tag; rebuild with our explicit iv
        var out = [UInt8]()
        out.reserveCapacity(1 + 12 + ct.count - 12)
        out.append(0xf1)
        out.append(contentsOf: iv)
        out.append(contentsOf: ct.dropFirst(12))
        return out
    }

    public static func gcmOpen(key: [UInt8], iv: [UInt8], ciphertextAndTag: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(iv)), ciphertext: Data(ciphertextAndTag.dropLast(16)), tag: Data(ciphertextAndTag.suffix(16)))
        return Array(try AES.GCM.open(box, using: SymmetricKey(data: Data(key))))
    }

    // MARK: zstd

    private static let zstdLevel: Int32 = 1

    public static func zstdCompress(_ data: [UInt8]) -> [UInt8]? {
        let src = data
        let bound = ZSTD_compressBound(src.count)
        var dst = [UInt8](repeating: 0, count: bound)
        let n = ZSTD_compress(&dst, dst.count, src, src.count, zstdLevel)
        if ZSTD_isError(n) != 0 { return nil } // caller drops the batch (server would reject raw bytes)
        return Array(dst[0..<n])
    }

    public static func zstdDecompress(_ data: [UInt8], maxOutput: Int = 65536) -> [UInt8]? {
        var dst = [UInt8](repeating: 0, count: maxOutput)
        let n = ZSTD_decompress(&dst, dst.count, data, data.count)
        if ZSTD_isError(n) != 0 { return nil }
        return Array(dst[0..<n])
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case crypto(String)
    case socket(String)
    case handshake(String)
    case dns(String)

    public var description: String {
        switch self {
        case .crypto(let s): return "crypto: \(s)"
        case .socket(let s): return "socket: \(s)"
        case .handshake(let s): return "handshake: \(s)"
        case .dns(let s): return "dns: \(s)"
        }
    }
}
