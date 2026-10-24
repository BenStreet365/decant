import Darwin
import Foundation

/// Checks that nobody but trusted accounts can change a path, so root does not run, or write
/// through, something a user can swap out.
public enum PathSafety {
    /// Groups whose members can become root anyway (wheel, admin), so a folder they can write to
    /// gives nobody new powers. `/Applications` is `root:admin` and group-writable, for example.
    static let privilegedGroups: Set<gid_t> = [0, 80]

    /// Why `path`, or a folder above it, could be changed by an account outside `trustedOwners`,
    /// or nil if it cannot. Both the path as given and the path its symlinks lead to are checked.
    /// Each component must be owned by a trusted account and not writable by group (unless the
    /// group is wheel or admin) or others; a sticky folder such as /tmp is allowed, because only
    /// an entry's owner may rename or remove it there.
    public static func problem(with path: String, trustedOwners: Set<uid_t> = [0]) -> String? {
        if let problem = problemWithComponents(of: path, trustedOwners: trustedOwners) { return problem }
        guard let resolved = realpath(path, nil) else { return "\(path) cannot be resolved: \(String(cString: strerror(errno)))" }
        defer { free(resolved) }
        let real = String(cString: resolved)
        return real == path ? nil : problemWithComponents(of: real, trustedOwners: trustedOwners)
    }

    static func problemWithComponents(of path: String, trustedOwners: Set<uid_t>) -> String? {
        guard path.hasPrefix("/") else { return "\(path) is not an absolute path" }
        var current = ""
        for component in [""] + path.split(separator: "/").map(String.init) {
            current = component.isEmpty ? "/" : (current == "/" ? "/\(component)" : "\(current)/\(component)")
            var st = stat()
            guard lstat(current, &st) == 0 else { return "\(current) cannot be inspected: \(String(cString: strerror(errno)))" }
            guard trustedOwners.contains(st.st_uid) else { return "\(current) is owned by uid \(st.st_uid)" }
            // A symlink's own mode means nothing; whoever can write to its folder could replace it.
            guard (st.st_mode & S_IFMT) != S_IFLNK else { continue }
            let sticky = (st.st_mode & S_IFMT) == S_IFDIR && st.st_mode & S_ISVTX != 0
            if st.st_mode & S_IWOTH != 0, !sticky { return "\(current) is writable by everyone" }
            if st.st_mode & S_IWGRP != 0, !sticky, !privilegedGroups.contains(st.st_gid) {
                return "\(current) is writable by group \(st.st_gid)"
            }
        }
        return nil
    }
}
