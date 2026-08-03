import Darwin
import Foundation

public enum FSMetaError: Error {
    case setattr(Int32)
    case setxattr(Int32)
}

// Full attribute name is the "com.apple.metadata" domain joined to the
// user-tags key; built by concatenation to keep the two apart in source.
private let tagsXattr = "com.apple.metadata:" + "_kMDItemUserTags"

public func dateAdded(of path: String) -> Date? {
    let url = URL(fileURLWithPath: path)
    if let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]),
        let date = values.addedToDirectoryDate
    {
        return date
    }
    return nil
}

public func setDateAdded(_ path: String, to date: Date) throws {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)

    var ts = timespec()
    let secs = date.timeIntervalSince1970
    ts.tv_sec = Int(secs)
    ts.tv_nsec = Int((secs - secs.rounded(.down)) * 1_000_000_000)

    let rc = withUnsafeMutablePointer(to: &ts) { tsPtr in
        setattrlist(path, &list, tsPtr, MemoryLayout<timespec>.size, 0)
    }
    if rc != 0 { throw FSMetaError.setattr(errno) }
}

public func rawTags(of path: String) -> [String] {
    let size = getxattr(path, tagsXattr, nil, 0, 0, 0)
    if size <= 0 { return [] }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { buf in
        getxattr(path, tagsXattr, buf.baseAddress, size, 0, 0)
    }
    if read <= 0 { return [] }
    let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return (list as? [String]) ?? []
}

/// Replaces Sift's own tag on an item, leaving the user's tags untouched.
/// `preserving` exempts specific Sift-owned entries from the strip — callers
/// pass `isKeepTag` so rewriting a countdown does not remove a pin. It has no
/// default value on purpose: silently defaulting to "preserve nothing" is
/// exactly how a keep tag would get eaten by a future call site.
/// All extended attributes of a file, raw. Captured before an optimize
/// replaces the file and restored after, so Finder tags (countdown, pins,
/// user tags) and anything else survive the swap.
public func captureXattrs(of path: String) -> [(name: String, data: Data)] {
    let size = listxattr(path, nil, 0, 0)
    if size <= 0 { return [] }
    var nameBuf = [CChar](repeating: 0, count: size)
    let read = listxattr(path, &nameBuf, size, 0)
    if read <= 0 { return [] }

    var names: [String] = []
    var start = 0
    for i in 0..<Int(read) where nameBuf[i] == 0 {
        let bytes = nameBuf[start..<i].map { UInt8(bitPattern: $0) }
        if !bytes.isEmpty, let name = String(bytes: bytes, encoding: .utf8) {
            names.append(name)
        }
        start = i + 1
    }

    var out: [(name: String, data: Data)] = []
    for name in names {
        let valueSize = getxattr(path, name, nil, 0, 0, 0)
        if valueSize < 0 { continue }
        var data = Data(count: valueSize)
        let valueRead = data.withUnsafeMutableBytes { buf in
            getxattr(path, name, buf.baseAddress, valueSize, 0, 0)
        }
        if valueRead >= 0 { out.append((name, data.prefix(valueRead))) }
    }
    return out
}

/// Best-effort restore; returns false if any attribute failed to write.
@discardableResult
public func restoreXattrs(_ attrs: [(name: String, data: Data)], to path: String) -> Bool {
    var ok = true
    for (name, data) in attrs {
        let rc = data.withUnsafeBytes { buf in
            setxattr(path, name, buf.baseAddress, buf.count, 0, 0)
        }
        if rc != 0 { ok = false }
    }
    return ok
}

/// Appends one Sift tag without disturbing any other entry. Idempotent: an
/// existing entry with the same name is replaced, nothing else is touched.
/// Used for persistent markers (`Sift · Optimized`), where `setSiftTag`'s
/// replace-the-transient-tags semantics would be wrong.
public func addSiftTag(_ path: String, text: String, color: Int) throws {
    var tags = rawTags(of: path).filter { entry in
        (entry.components(separatedBy: "\n").first ?? entry) != text
    }
    tags.append("\(text)\n\(color)")
    let data = try PropertyListSerialization.data(
        fromPropertyList: tags, format: .binary, options: 0)
    let rc = data.withUnsafeBytes { buf in
        setxattr(path, tagsXattr, buf.baseAddress, buf.count, 0, 0)
    }
    if rc != 0 { throw FSMetaError.setxattr(errno) }
}

public func setSiftTag(
    _ path: String, text: String?, color: Int, prefix: String,
    preserving: (String) -> Bool
) throws {
    let ownPrefix = prefix + " · "
    var tags = rawTags(of: path).filter { entry in
        // Tag entries may carry a "\n<colorIndex>" suffix; compare on the name.
        let name = entry.components(separatedBy: "\n").first ?? entry
        return !name.hasPrefix(ownPrefix) || preserving(entry)
    }
    if let text = text {
        tags.append("\(text)\n\(color)")
    }
    let data = try PropertyListSerialization.data(
        fromPropertyList: tags, format: .binary, options: 0)
    let rc = data.withUnsafeBytes { buf in
        setxattr(path, tagsXattr, buf.baseAddress, buf.count, 0, 0)
    }
    if rc != 0 { throw FSMetaError.setxattr(errno) }
}
