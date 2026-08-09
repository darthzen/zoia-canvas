import Foundation

extension ZoiaPatchBinary {
    /// Encodes a patch back to the on-device `.bin` layout, ported from
    /// zoia_lib's `patch_encode.py`. The size word and per-module sizes are
    /// recomputed from content; everything else comes from the raw fields,
    /// so decode → encode reproduces the original bytes through the
    /// declared size. Output is always exactly 32768 bytes, zero-padded.
    static func encode(_ patch: ZoiaPatch) -> Data {
        var body = Data()

        body.append(fixed16(patch.nameRaw))
        appendWord(&body, patch.modules.count)

        for module in patch.modules {
            let sizeWords = ZoiaModuleEntry.headerWords + module.paramsRaw.count
                + module.savedData.count / 4 + ZoiaModuleEntry.nameWords
            appendWord(&body, sizeWords)
            appendWord(&body, module.typeID)
            appendWord(&body, module.version)
            appendWord(&body, module.pageRaw)
            appendWord(&body, module.headerColorID)
            appendWord(&body, module.position)
            appendWord(&body, module.paramsRaw.count)
            appendWord(&body, module.savedDataSizeField)
            body.append(contentsOf: module.optionBytes.prefix(8))
            body.append(contentsOf: repeatElement(0, count: max(0, 8 - module.optionBytes.count)))
            for value in module.paramsRaw {
                appendWord(&body, value)
            }
            body.append(module.savedData)
            body.append(fixed16(module.nameRaw))
        }

        appendWord(&body, patch.connections.count)
        for connection in patch.connections {
            appendWord(&body, connection.sourceModule)
            appendWord(&body, connection.sourceBlock)
            appendWord(&body, connection.destModule)
            appendWord(&body, connection.destBlock)
            appendWord(&body, connection.strengthRaw)
        }

        appendWord(&body, patch.pageCountRaw)
        for pageName in patch.pageNamesRaw {
            body.append(fixed16(pageName))
        }

        appendWord(&body, patch.starred.count)
        for star in patch.starred {
            let low = UInt32(UInt16(bitPattern: Int16(truncatingIfNeeded: star.moduleIndex)))
            let high = UInt32(UInt16(bitPattern: Int16(truncatingIfNeeded: star.blockField)))
            appendWord(&body, Int(Int32(bitPattern: low | (high << 16))))
        }

        for color in patch.colors {
            appendWord(&body, color)
        }

        // The size word counts itself.
        var file = Data(capacity: fileSize)
        appendWord(&file, body.count / 4 + 1)
        file.append(body)
        file.append(Data(count: fileSize - file.count))
        return file
    }

    private static func appendWord(_ data: inout Data, _ value: Int) {
        withUnsafeBytes(of: Int32(truncatingIfNeeded: value).littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func fixed16(_ raw: Data) -> Data {
        if raw.count == 16 { return raw }
        var out = raw.prefix(16)
        out.append(Data(count: 16 - out.count))
        return out
    }
}
