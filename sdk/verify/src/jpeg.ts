import { concat, equal, utf8 } from "./bytes.ts";
import { parseProof, type PupilleProof } from "./proof.ts";

/**
 * The proof travels inside the JPEG as one APP11 segment tagged "PUPILLE\0".
 * The certificates hash the original camera bytes, so a verifier removes exactly
 * that segment and gets the signed bytes back. (C2PA uses the same idea: its
 * manifest lives in APP11 and is excluded from the content hash.)
 */
const APP11 = 0xeb;
const IDENTIFIER = utf8("PUPILLE\0");
const MAX_PAYLOAD = 0xffff - 2 - IDENTIFIER.length;

export class JpegError extends Error {}

interface Segment { marker: number; start: number; end: number }

/** Header segments between SOI and SOS. Image data after SOS is never touched. */
function headerSegments(jpeg: Uint8Array): Segment[] {
  if (jpeg.length < 4 || jpeg[0] !== 0xff || jpeg[1] !== 0xd8) throw new JpegError("not a JPEG file");
  const segments: Segment[] = [];
  let offset = 2;
  while (offset + 4 <= jpeg.length) {
    if (jpeg[offset] !== 0xff) throw new JpegError("malformed JPEG header");
    const marker = jpeg[offset + 1];
    if (marker === 0xff) { offset += 1; continue; } // fill byte
    if (marker === 0xda || marker === 0xd9) break; // start of scan / end of image
    const length = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
    if (length < 2 || offset + 2 + length > jpeg.length) throw new JpegError("truncated JPEG segment");
    segments.push({ marker, start: offset, end: offset + 2 + length });
    offset += 2 + length;
  }
  return segments;
}

function isPupilleSegment(jpeg: Uint8Array, segment: Segment): boolean {
  return segment.marker === APP11 && segment.end - segment.start >= 4 + IDENTIFIER.length
    && equal(jpeg.subarray(segment.start + 4, segment.start + 4 + IDENTIFIER.length), IDENTIFIER);
}

/**
 * Returns a copy of `jpeg` carrying `proof`. Any earlier Pupille proof is replaced.
 * The segment goes after the leading APPn segments so EXIF/JFIF stay first.
 */
export function embedProof(jpeg: Uint8Array, proof: PupilleProof): Uint8Array {
  const original = extractProof(jpeg).imageBytes;
  const payload = utf8(JSON.stringify(proof));
  if (payload.length > MAX_PAYLOAD) throw new JpegError("proof does not fit in one JPEG segment");
  const length = 2 + IDENTIFIER.length + payload.length;
  const segment = concat(new Uint8Array([0xff, APP11, length >> 8, length & 0xff]), IDENTIFIER, payload);

  let insertAt = 2;
  for (const s of headerSegments(original)) {
    if (s.marker < 0xe0 || s.marker > 0xef) break;
    insertAt = s.end;
  }
  return concat(original.subarray(0, insertAt), segment, original.subarray(insertAt));
}

/**
 * Splits a file into the proof it carries (if any) and the original image bytes.
 * `proof` is null when the file has no Pupille segment or the segment is unreadable.
 */
export function extractProof(jpeg: Uint8Array): { proof: PupilleProof | null; imageBytes: Uint8Array } {
  const found = headerSegments(jpeg).find((s) => isPupilleSegment(jpeg, s));
  if (!found) return { proof: null, imageBytes: jpeg };
  const payload = jpeg.subarray(found.start + 4 + IDENTIFIER.length, found.end);
  return {
    proof: parseProof(new TextDecoder().decode(payload)),
    imageBytes: concat(jpeg.subarray(0, found.start), jpeg.subarray(found.end)),
  };
}
