import Foundation
import Compression

/// gzip, for compressing the answer request body.
///
/// Why: on a weak or lossy link (a phone hotspot dropping 15% of packets was measured on
/// 2026-10-01) every packet lost costs a retransmission wait, so the fewer packets a request
/// needs, the fewer chances there are to lose one. The answer request is 13 to 30 KB of JSON
/// that is mostly repeated prompt text, and compresses to roughly a third. The server accepts
/// `Content-Encoding: gzip` (GzipRequestFilter, decompressed cap 8 MB) and ignores everything
/// else, so a client that does not compress is unaffected.
///
/// Compression's COMPRESSION_ZLIB is raw deflate (RFC 1951) with no header, so the gzip
/// container (RFC 1952: ten-byte header, the deflate stream, CRC-32 and the original size) is
/// written here.
enum Gzip {
    /// Below this the saving is not worth the CPU or the extra header bytes.
    static let minimumSize = 1024

    static func compress(_ input: Data) -> Data? {
        guard input.count >= minimumSize else { return nil }
        let capacity = input.count + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let written = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&out, capacity, base, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written + 18 < input.count else { return nil }   // not smaller: send it plain

        var gz = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])      // magic, deflate, no flags, no mtime, OS unknown
        gz.append(contentsOf: out[0..<written])
        var crc = crc32(input).littleEndian
        var size = UInt32(truncatingIfNeeded: input.count).littleEndian
        gz.append(Data(bytes: &crc, count: 4))
        gz.append(Data(bytes: &size, count: 4))
        return gz
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
