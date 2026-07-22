import Foundation
import SiftCore

let argv = Array(CommandLine.arguments.dropFirst())
exit(runCLI(argv))
