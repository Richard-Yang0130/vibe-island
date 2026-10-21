#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Both transports use the same private directory and fail closed for unsafe endpoints.
public enum AgentTaskSocketSecurity {
    public enum Failure: Error {
        case unsafePath
        case system(Int32)
    }

    public static func path(uid: UInt32, fileName: String) -> String {
        #if canImport(Darwin)
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: count)
        let written = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, count)
        guard written > 1, written <= count else { return "" }
        guard let value = String(bytes: buffer.prefix(written - 1).map { UInt8(bitPattern: $0) }, encoding: .utf8)
        else { return "" }
        let root = URL(fileURLWithPath: value).resolvingSymlinksInPath().path
        #else
        let root = "/run/user/\(uid)"
        #endif
        return "\(root)/cb-\(uid)/\(fileName)"
    }

    public static func prepareServer(path: String, uid: UInt32 = getuid()) throws {
        try self.validatePath(path)
        let parent = (path as NSString).deletingLastPathComponent
        if try self.attributes(parent) == nil {
            try self.validateDirectory((parent as NSString).deletingLastPathComponent, uid: uid)
            guard mkdir(parent, 0o700) == 0 || errno == EEXIST else { throw Failure.system(errno) }
        }
        try self.validateDirectory(parent, uid: uid)
        if try self.attributes(path) != nil {
            try self.removeServerSocket(path: path, uid: uid)
        }
    }

    public static func secureServerSocket(path: String, uid: UInt32 = getuid()) throws {
        try self.validatePath(path)
        try self.validateDirectory((path as NSString).deletingLastPathComponent, uid: uid)
        try self.validateSocket(path, uid: uid, permissions: nil)
        guard chmod(path, 0o600) == 0 else { throw Failure.system(errno) }
        try self.validateClient(path: path, uid: uid)
    }

    public static func validateClient(path: String, uid: UInt32 = getuid()) throws {
        try self.validatePath(path)
        try self.validateDirectory((path as NSString).deletingLastPathComponent, uid: uid)
        try self.validateSocket(path, uid: uid, permissions: 0o600)
    }

    public static func removeServerSocket(path: String, uid: UInt32 = getuid()) throws {
        try self.validateClient(path: path, uid: uid)
        guard unlink(path) == 0 else { throw Failure.system(errno) }
    }

    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        else { throw Failure.unsafePath }
    }

    private static func validateDirectory(_ path: String, uid: UInt32) throws {
        guard let info = try self.attributes(path), info.st_uid == uid,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700
        else { throw Failure.unsafePath }
    }

    private static func validateSocket(_ path: String, uid: UInt32, permissions: mode_t?) throws {
        guard let info = try self.attributes(path), info.st_uid == uid,
              info.st_mode & S_IFMT == S_IFSOCK,
              permissions == nil || info.st_mode & 0o7777 == permissions
        else { throw Failure.unsafePath }
    }

    private static func attributes(_ path: String) throws -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.system(errno)
        }
        return info
    }
}
