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
/// Track 1's matrix row is NOT authoritative — in 21 of 77 corpus
/// instances it disagrees with the params (stale or phase-rotated).
/// Track 1 plays from params; rows 1…7 are the only storage for
/// tracks 2…8.
enum SequencerSavedData {
    static let maxTracks = 8
    static let maxSteps = 32
    /// Step matrix size; the smallest valid blob (572 bytes) always
    /// contains it in full.
    static let stepMatrixBytes = maxTracks * maxSteps * 2

    /// Step value as the 0…1 fraction the runtime and UI use, or nil when
    /// the blob has no matrix (canvas-authored modules start empty).
    static func step(_ data: Data, track: Int, step: Int) -> Float? {
        guard (0..<maxTracks).contains(track), (0..<maxSteps).contains(step),
              data.count >= stepMatrixBytes else { return nil }
        let offset = data.startIndex + (track * maxSteps + step) * 2
        let raw = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        return Float(raw) / 65535
    }
}
