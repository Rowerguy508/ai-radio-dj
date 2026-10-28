import Foundation

/// Extracts the pinned Phonon 31m zip after its SHA-256 has already matched.
/// Rejects paths that leave the bundle directory, zip64, encryption, and data
/// descriptors. Returns false without loading a model when the archive is not
/// the layout `PhononBundlePath` allows.
enum PhononZip {
    private static let localHeader = 0x0403_4b50
    private static let maxFileBytes = 64 * 1024 * 1024
    private static let maxTotalBytes = 200 * 1024 * 1024
    private static let maxFiles = 200

    static func extract(_ zip: URL, to destination: URL) -> Bool {
        guard let data = try? Data(contentsOf: zip), data.count >= 30 else { return false }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return false
        }
        var offset = 0
        var files = 0
        var total = 0
        while offset + 30 <= data.count {
            let signature = u32(data, offset)
            if signature != localHeader { break }
            let flags = Int(u16(data, offset + 6))
            let method = Int(u16(data, offset + 8))
            let compressed = Int(u32(data, offset + 18))
            let uncompressed = Int(u32(data, offset + 22))
            let nameLength = Int(u16(data, offset + 26))
            let extraLength = Int(u16(data, offset + 28))
            if flags & 0x1 != 0 || flags & 0x8 != 0 { return wipe(destination) }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF { return wipe(destination) }
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + compressed
            guard nameEnd <= data.count, dataEnd <= data.count, compressed >= 0, uncompressed >= 0 else {
                return wipe(destination)
            }
            let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""
            guard let relative = PhononBundlePath.relativePath(forZipEntry: name) else { return wipe(destination) }
            if uncompressed > maxFileBytes || total > maxTotalBytes - uncompressed { return wipe(destination) }
            if !relative.isEmpty && !name.hasSuffix("/") {
                guard let payload = inflate(data, start: dataStart, compressed: compressed, uncompressed: uncompressed, method: method) else {
                    return wipe(destination)
                }
                let dest = nested(relative, under: destination)
                guard inside(dest, of: destination) else { return wipe(destination) }
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try payload.write(to: dest, options: .atomic)
                } catch {
                    return wipe(destination)
                }
                files += 1
                total += uncompressed
                if files > maxFiles { return wipe(destination) }
            }
            offset = dataEnd
        }
        return files > 0
    }

    private static func inflate(_ data: Data, start: Int, compressed: Int, uncompressed: Int, method: Int) -> Data? {
        if uncompressed == 0 { return Data() }
        if method == 0 {
            guard compressed == uncompressed else { return nil }
            return data.subdata(in: start..<(start + compressed))
        }
        guard method == 8, compressed <= UInt32.max, uncompressed <= UInt32.max else { return nil }
        var output = Data(count: uncompressed)
        let source = data.subdata(in: start..<(start + compressed))
        let rc: Int32 = output.withUnsafeMutableBytes { dst in
            source.withUnsafeBytes { src in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 1 }
                return aerodj_inflate_raw(srcBase, UInt32(compressed), dstBase, UInt32(uncompressed))
            }
        }
        return rc == 0 ? output : nil
    }

    private static func nested(_ relative: String, under root: URL) -> URL {
        relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private static func inside(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func wipe(_ destination: URL) -> Bool {
        try? FileManager.default.removeItem(at: destination)
        return false
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            | UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for shift in 0..<4 {
            value |= UInt32(data[data.index(data.startIndex, offsetBy: offset + shift)]) << (8 * shift)
        }
        return value
    }
}
