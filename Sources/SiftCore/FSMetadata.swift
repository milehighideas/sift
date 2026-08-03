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
