import AppKit
import Common
import Foundation

struct SaveStateCommand: Command {
    let args: SaveStateCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let filePath = args.filePath ?? config.stateFilePath else {
            return io.err("No file path provided and 'state-file' not configured in aerospace.toml")
        }

        switch await saveState(to: filePath) {
        case .success(let path):
            io.out("State saved to \(path)")
            return true
        case .failure(let error):
            return io.err(error)
        }
    }
}

/// Save current window state to file. Returns the expanded path on success.
@MainActor
func saveState(to filePath: String) async -> Result<String, String> {
    let expandedPath = (filePath as NSString).expandingTildeInPath
    let fileUrl = URL(fileURLWithPath: expandedPath)

    // Read existing state file if it exists (for merging)
    var existingWorld: SerializedWorld? = nil
    if let existingData = try? Data(contentsOf: fileUrl),
       let decoded = try? JSONDecoder().decode(SerializedWorld.self, from: existingData) {
        existingWorld = decoded
    }

    // Collect all window data (title and rect) asynchronously
    var windowData: [UInt32: WindowSaveData] = [:]
    for workspace in Workspace.all {
        for window in workspace.allLeafWindowsRecursive {
            if let title = try? await window.title,
               let rect = try? await window.getAxRect() {
                windowData[window.windowId] = WindowSaveData(title: title, rect: rect)
            }
        }
    }

    // Create the serialized world, merging with existing state
    let serializedWorld = SerializedWorld(
        workspaces: Workspace.all,
        monitors: monitors,
        windowData: windowData,
        existingWorld: existingWorld
    )

    // Encode to JSON
    guard let jsonData = try? JSONEncoder.aeroSpaceDefault.encode(serializedWorld) else {
        return .failure("Failed to encode state to JSON")
    }

    // Write to file
    do {
        try jsonData.write(to: fileUrl)
        return .success(expandedPath)
    } catch {
        return .failure("Failed to write state to file: \(error.localizedDescription)")
    }
}

/// Auto-save state if state-file is configured
@MainActor
func autoSaveStateIfConfigured() async {
    guard let filePath = config.stateFilePath else { return }
    _ = await saveState(to: filePath)
}
