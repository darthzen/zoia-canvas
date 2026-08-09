import Foundation
import Testing
@testable import ZoiaCanvas

private final class CorpusLocator {}

private func devicePatches() throws -> [(relPath: String, data: Data)] {
    let bundle = Bundle(for: CorpusLocator.self)
    let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
    let nonPatches: Set<String> = ["_zoia_.bin", "Factory/062_zoia_.bin", "input_test.bin"]
    let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "bin" } ?? []
    return try all
        .map { url in
            let components = url.pathComponents.drop { $0 != "Corpus" }.dropFirst()
            return (components.joined(separator: "/"), url)
        }
        .filter { !nonPatches.contains($0.0) }
        .sorted { $0.0 < $1.0 }
        .map { ($0.0, try Data(contentsOf: $0.1)) }
}

@Suite struct PatchEncoderTests {
    /// The acceptance gate for the encoder: decode → encode is
    /// byte-identical through the declared size for every device patch.
    @Test func roundTripsEveryDevicePatch() throws {
        var checked = 0
        for (relPath, original) in try devicePatches() {
            let patch = try ZoiaPatchBinary.decode(original)
            let encoded = ZoiaPatchBinary.encode(patch)
            #expect(encoded.count == ZoiaPatchBinary.fileSize, "\(relPath) size")

            let declaredBytes = patch.declaredSizeWords * 4
            if encoded.prefix(declaredBytes) != original.prefix(declaredBytes) {
                let mismatch = zip(encoded, original).enumerated()
                    .first { $0.element.0 != $0.element.1 }
                Issue.record("\(relPath): first mismatch at byte \(mismatch?.offset ?? -1)")
            } else {
                checked += 1
            }
        }
        #expect(checked == 127)
    }

    /// Bytes past the declared size must be zero padding in our output.
    @Test func padsWithZeros() throws {
        for (relPath, original) in try devicePatches() {
            let patch = try ZoiaPatchBinary.decode(original)
            let encoded = ZoiaPatchBinary.encode(patch)
            let declaredBytes = patch.declaredSizeWords * 4
            #expect(encoded.dropFirst(declaredBytes).allSatisfy { $0 == 0 }, "\(relPath)")
        }
    }

    /// The recomputed size word must agree with the file's declared size —
    /// proof the corpus files are internally consistent and our size math
    /// matches the device's.
    @Test func recomputedSizeMatchesDeclared() throws {
        for (relPath, original) in try devicePatches() {
            let patch = try ZoiaPatchBinary.decode(original)
            let encoded = ZoiaPatchBinary.encode(patch)
            let declared = encoded.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            #expect(Int(Int32(littleEndian: declared)) == patch.declaredSizeWords, "\(relPath)")
        }
    }
}
