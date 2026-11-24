import Foundation
import PagesMCPCore

// Launcher only. Everything testable lives in PagesMCPCore, which the test target
// imports; an executable target cannot be imported.
//
// Settings come from the Claude extension manifest, which substitutes the person's
// user_config into this process's arguments.
await PagesMCPServer.run(
    configuration: Configuration.parse(Array(CommandLine.arguments.dropFirst())))
