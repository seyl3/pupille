import Foundation

/// Carries a proof inside a JPEG as one APP11 segment tagged "PUPILLE\0", the same
/// format as `@pupille/verify`. The certificates hash the original camera bytes, so
/// extracting removes exactly that segment and returns the signed bytes.
public enum ProofJPEG {
    private static let app11: UInt8 = 0xEB
    private static let identifier = Data("PUPILLE\0".utf8)

    private struct Segment { let marker: UInt8; let range: Range<Int> }

    private static func headerSegments(_ jpeg: [UInt8]) throws -> [Segment] {
        guard jpeg.count >= 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { throw PupilleError.notAJPEG }
        var segments: [Segment] = []
        var offset = 2
        while offset + 4 <= jpeg.count {
            guard jpeg[offset] == 0xFF else { throw PupilleError.notAJPEG }
            let marker = jpeg[offset + 1]
            if marker == 0xFF { offset += 1; continue }
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(jpeg[offset + 2]) << 8 | Int(jpeg[offset + 3])
            guard length >= 2, offset + 2 + length <= jpeg.count else { throw PupilleError.notAJPEG }
            segments.append(Segment(marker: marker, range: offset..<(offset + 2 + length)))
            offset += 2 + length
        }
        return segments
    }

    private static func isProof(_ jpeg: [UInt8], _ segment: Segment) -> Bool {
        let start = segment.range.lowerBound + 4
        return segment.marker == app11 && segment.range.upperBound >= start + identifier.count
            && Data(jpeg[start..<(start + identifier.count)]) == identifier
    }

    /// A copy of `jpeg` carrying `proof`, after the leading APPn segments so EXIF stays first.
    public static func embed(_ proof: PupilleProof, in jpeg: Data) throws -> Data {
        let original = Array(try extract(from: jpeg).imageData)
        let payload = try JSONEncoder().encode(proof)
        let length = 2 + identifier.count + payload.count
        guard length <= 0xFFFF else { throw PupilleError.proofTooLarge }
        var insertAt = 2
        for segment in try headerSegments(original) {
            guard (0xE0...0xEF).contains(segment.marker) else { break }
            insertAt = segment.range.upperBound
        }
        var out = Data(original[..<insertAt])
        out.append(contentsOf: [0xFF, app11, UInt8(length >> 8), UInt8(length & 0xFF)])
        out.append(identifier)
        out.append(payload)
        out.append(contentsOf: original[insertAt...])
        return out
    }

    /// Splits a file into its proof (if any) and the original image bytes.
    public static func extract(from jpeg: Data) throws -> (proof: PupilleProof?, imageData: Data) {
        let bytes = Array(jpeg)
        guard let segment = try headerSegments(bytes).first(where: { isProof(bytes, $0) }) else {
            return (nil, jpeg)
        }
        let payload = Data(bytes[(segment.range.lowerBound + 4 + identifier.count)..<segment.range.upperBound])
        var image = Data(bytes[..<segment.range.lowerBound])
        image.append(contentsOf: bytes[segment.range.upperBound...])
        return (try? JSONDecoder().decode(PupilleProof.self, from: payload), image)
    }
}
