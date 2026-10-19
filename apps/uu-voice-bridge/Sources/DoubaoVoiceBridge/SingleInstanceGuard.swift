import Darwin
import Foundation

/// The lock follows the GUI process lifetime, including abnormal termination.
/// Never unlink the file: doing so would allow a new inode to bypass an existing lock.
final class SingleInstanceGuard {
    private var descriptor: Int32 = -1

    deinit { release() }

    @discardableResult
    func acquire(at url: URL? = nil) -> Bool {
        guard descriptor == -1 else { return true }
        let lockURL = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("com.lyp.DoubaoVoiceBridge.Fn.gui.lock", isDirectory: false)
        let opened = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard opened >= 0 else { return false }
        var information = stat()
        guard fstat(opened, &information) == 0,
              (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              information.st_uid == geteuid(),
              flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(opened)
            return false
        }
        descriptor = opened
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}
