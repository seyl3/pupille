import Foundation

/// Minimal Keccak-256 (the original Keccak padding used by Ethereum/World's
/// `hash_to_field`, NOT NIST SHA3-256 which uses different domain-separation
/// padding bits). Vendored because idkit-swift ships a precompiled XCFramework
/// (Rust core via UniFFI) that only links on Apple platforms, so `IDKit.hashSignal`
/// is unavailable on Linux (see docs/WORKLOG.md). Verified byte-exact against
/// `@worldcoin/idkit-core/hashing`'s `hashSignal` output for every §06 test vector
/// in PupilleCoreTests.
enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ]

    private static let rotationOffsets: [[Int]] = [
        [0, 36, 3, 41, 18],
        [1, 44, 10, 45, 2],
        [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14]
    ]

    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 {
        n == 0 ? x : (x << UInt64(n)) | (x >> UInt64(64 - n))
    }

    private static func keccakF1600(_ state: inout [UInt64]) {
        for round in 0..<24 {
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] ^= d[x]
                }
            }

            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    let newX = y
                    let newY = (2 * x + 3 * y) % 5
                    b[newX + 5 * newY] = rotl(state[x + 5 * y], rotationOffsets[x][y])
                }
            }

            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
                }
            }

            state[0] ^= roundConstants[round]
        }
    }

    /// Keccak-256 (original padding: 0x01 domain byte, not SHA3's 0x06).
    static func hash(_ input: [UInt8]) -> [UInt8] {
        let rateBytes = 136 // 1088 bits / 8, for 256-bit output (capacity = 512 bits)
        var state = [UInt64](repeating: 0, count: 25)

        var padded = input
        padded.append(0x01)
        while padded.count % rateBytes != 0 { padded.append(0x00) }
        padded[padded.count - 1] |= 0x80

        for blockStart in stride(from: 0, to: padded.count, by: rateBytes) {
            for i in 0..<(rateBytes / 8) {
                var lane: UInt64 = 0
                for j in 0..<8 {
                    lane |= UInt64(padded[blockStart + i * 8 + j]) << (8 * j)
                }
                state[i] ^= lane
            }
            keccakF1600(&state)
        }

        var output = [UInt8]()
        output.reserveCapacity(32)
        var laneIndex = 0
        while output.count < 32 {
            let lane = state[laneIndex]
            for j in 0..<8 where output.count < 32 {
                output.append(UInt8((lane >> (8 * j)) & 0xff))
            }
            laneIndex += 1
        }
        return output
    }
}
