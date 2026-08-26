import Darwin
import Foundation

/// On-disk locations for the app shell. Paths are resolved through
/// `FileManager` so App Sandbox (#73) automatically relocates them into the
/// container; do not hard-code `~/Library/Application Support/...`.
///
/// When #73 turns sandboxing on, a ledger written by an unsandboxed #36
/// build will sit outside the container. Migrating that file is #73's job,
/// not this ticket's — #62's login-item relaunch uses the same API so both
/// see one location for a given sandbox state.
public enum LiraPaths {
    public static let applicationSupportFolderName = "Lira"
    public static let ledgerFileName = "ledger.sqlite"

    /// Darwin `sockaddr_un.sun_path` limit including the trailing NUL.
    public static let maxUnixSocketPathLength = 104

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    public static func ledgerURL(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent(ledgerFileName)
    }

    /// Prefers a socket next to the ledger. If that path would exceed the
    /// AF_UNIX cap (sandbox container paths are long), fall back to a short
    /// owner-only directory under `/tmp`.
    public static func ipcSocketURL(fileManager: FileManager = .default) -> URL {
        let preferred = applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("ipc", isDirectory: true)
            .appendingPathComponent("core.sock")
        if preferred.path.utf8.count < maxUnixSocketPathLength {
            return preferred
        }
        return URL(fileURLWithPath: "/tmp/lira-\(getuid())/core.sock")
    }
}

public enum LiraComponent {
    public static let core = ComponentID("lira.core")
    public static let app = ComponentID("lira.app")
}

public enum AppEventType {
    public static let launched = "app.launched"
}

public enum AppProducer {
    public static let shell = "lira.app"
}
