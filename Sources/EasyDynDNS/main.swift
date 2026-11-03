import Foundation

// With a command argument the binary acts as a CLI; otherwise it starts the menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, CLI.isCommand(command) {
    Task {
        let code = await CLI.main(arguments)
        exit(code)
    }
    dispatchMain()
} else {
    EasyDynDNSApp.main()
}
