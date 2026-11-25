import Foundation
import PagesMCPCore

// Launcher only. Everything testable lives in PagesMCPCore, which the test target
// imports; an executable target cannot be imported.
//
// The server takes no settings: its sizes are constants in `ToolCatalog`.
await PagesMCPServer.run()
