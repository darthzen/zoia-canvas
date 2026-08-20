import Foundation

/// Decoded layout of the sequencer's (typeID 4) saved_data blob.
///
/// Derived by correlating all 77 sequencer instances in the factory
/// corpus against their option bytes (steps = byte0+1, tracks = byte1+1,
/// both confirmed by pcount = steps + gate + restart on every instance):
///
/// - Bytes 0…511: the step matrix — 8 track rows × 32 steps, each step a
///   little-endian uint16 holding the value × 65535, track-major. Fixed
///   size regardless of the active step/track options; slots beyond the
///   active range hold stale values from earlier edits, not zeros.
/// - Bytes 512…571: metadata, undecoded. Observed: UI cursor bytes, eight
///   per-track words defaulting to 1…8, two counters, per-track 0x01
///   flag bytes. Nothing here is needed to play the patch.
/// - The blob is 572 bytes in older firmware and 4156 in newer; in every
///   corpus instance the 4156-byte tail past 572 is zero.
///
/// Track 1's matrix row disagrees with the params in 21 of 77 corpus
/// instances (stale or phase-rotated), so the params are the better
/// source for track 1 — but whether the device reads that track from
/// params or the matrix is unverified. Device-written patches
/// (000_zoia_.bin, 2026-08-19) keep both in sync, so the canvas does
/// too: step-param edits mirror into the matrix via `setStep`. Rows
/// 1…7 are the only storage for tracks 2…8.
enum SequencerSavedData {
    static let maxTracks = 8
    static let maxSteps = 32
    /// Step matrix size; the smallest valid blob (572 bytes) always
    /// contains it in full.
    static let stepMatrixBytes = maxTracks * maxSteps * 2
    /// Smallest blob the device writes: the matrix plus 60 metadata bytes.
    static let blobBytes = 572

    /// Step value as the 0…1 fraction the runtime and UI use, or nil when
    /// the blob has no matrix (canvas-authored modules start empty).
    static func step(_ data: Data, track: Int, step: Int) -> Float? {
        guard (0..<maxTracks).contains(track), (0..<maxSteps).contains(step),
              data.count >= stepMatrixBytes else { return nil }
        let offset = data.startIndex + (track * maxSteps + step) * 2
        let raw = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        return Float(raw) / 65535
    }

    /// A fresh 572-byte blob: all-zero matrix plus the metadata copied
    /// verbatim from a device-written module (000_zoia_.bin) — cursor
    /// word, per-track words 1…8, two counters, eight undecoded 0x01
    /// bytes, and eight track-type bytes (0 = CV; 1 = gate discards note
    /// values, 2 = ratchet). Every synthesized field we guessed at
    /// instead of copying cost a hardware debugging round.
    static func emptyBlob() -> Data {
        var blob = Data(count: blobBytes)
        let metaWords: [Int32] = [256, 1, 2, 3, 4, 5, 6, 7, 8, 203, 102]
        for (i, word) in metaWords.enumerated() {
            withUnsafeBytes(of: word.littleEndian) {
                blob.replaceSubrange(512 + i * 4..<512 + i * 4 + 4, with: $0)
            }
        }
        for i in 556..<564 { blob[i] = 0x01 }
        return blob
    }

    /// Writes one step's raw ×65535 value into the matrix, synthesizing
    /// the blob first for canvas-authored modules that have none.
    static func setStep(_ data: inout Data, track: Int, step: Int, rawValue: Int) {
        guard (0..<maxTracks).contains(track), (0..<maxSteps).contains(step) else { return }
        if data.count < stepMatrixBytes { data = emptyBlob() }
        let raw = UInt16(clamping: rawValue)
        let offset = data.startIndex + (track * maxSteps + step) * 2
        data[offset] = UInt8(raw & 0xFF)
        data[offset + 1] = UInt8(raw >> 8)
    }
}
