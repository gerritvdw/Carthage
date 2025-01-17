import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveSwift
import XCDBLD
import Curry

/// Type that encapsulates the configuration and evaluation of the `diagnose` subcommand.
public struct DiagnoseCommand: CommandProtocol {
    public struct Options: OptionsProtocol {
        public let outputPath: String?
        public let directoryPath: String
        public let mappingsFilePath: String?
        public let isVerbose: Bool
        public let ignoreErrors: Bool
        public let useNetrc: Bool
        public let colorOptions: ColorOptions

        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            let verboseOption = Option(key: "verbose", defaultValue: false, usage: "show verbose dependency info as it is resolved")
            let ignoreErrorsOption = Option(key: "ignore-errors", defaultValue: false, usage: "whether errors should be ignored while retrieving dependency information")
            return curry(self.init)
                <*> mode <| Option(
                    key: "output-path",
                    defaultValue: nil,
                    usage: "the directory path where to output the diagnosis information, if not specified a temporary directory will be used"
                )
                <*> mode <| Option(
                    key: "project-directory",
                    defaultValue: FileManager.default.currentDirectoryPath,
                    usage: "the directory containing the Carthage project, defaults to the current directory"
                )
                <*> mode <| Option(
                    key: "mappings-file",
                    defaultValue: nil,
                    usage: "an optional file containing mappings for dependencies to anonymize during the storage" +
                    " with format: <dependency string>=<mapped dependency string> (one mapping per line)")
                <*> mode <| verboseOption
                <*> mode <| ignoreErrorsOption
                <*> mode <| SharedOptions.netrcOption
                <*> ColorOptions.evaluate(mode)
        }

        /// Attempts to load the project referenced by the options
        public func loadProject() -> SignalProducer<Project, CarthageError> {
            let directoryURL = URL(fileURLWithPath: self.directoryPath, isDirectory: true)
            let project: Project = Project(directoryURL: directoryURL, useNetrc: self.useNetrc)

            let eventSink = ProjectEventLogger(colorOptions: self.colorOptions)
            project.projectEvents.observeValues { eventSink.log(event: $0) }

            return SignalProducer(value: project)
        }
    }

    public let verb = "diagnose"
    public let function = "Stores the project's dependencies into json files and copies the Cartfile for offline diagnosis of problematic dependency trees"

    public func run(_ options: Options) -> Result<(), CarthageError> {
        return storeDependenciesWithOptions(options)
            .waitOnCommand()
    }

    public func storeDependenciesWithOptions(_ options: Options) -> SignalProducer<URL, CarthageError> {
        return options.loadProject().flatMap(.merge) { project -> SignalProducer<URL, CarthageError> in
            do {
                let formatting = options.colorOptions.formatting
                let baseUrl = self.repositoryURL(for: options.outputPath)
                if FileManager.default.fileExists(atPath: baseUrl.path) {
                    try FileManager.default.removeItem(at: baseUrl)
                }

                let repositoryUrl = baseUrl.appendingPathComponent("Repository")

                carthage.printOut(formatting.bullets + "Started storing diagnosis info into directory: \(baseUrl.path)")

                let repository = LocalDependencyStore(directoryURL: repositoryUrl)
                var dependencyMappings: [Dependency: Dependency]?
                if let mappingsFilePath = options.mappingsFilePath {
                    carthage.printOut(formatting.bullets + "Using dependency mappings from file: \(mappingsFilePath)")
                    dependencyMappings = try self.mappings(from: mappingsFilePath)
                }
                let logger = ResolverEventLogger(colorOptions: options.colorOptions, verbose: options.isVerbose)

                return project.storeDependencies(to: repository,
                                                 ignoreErrors: options.ignoreErrors,
                                                 dependencyMappings: dependencyMappings,
                                                 eventObserver: { logger.log(event: $0) })
                    .attemptMap { cartfiles -> Result<URL, CarthageError> in
                        let cartfileURL = self.writeCartfile(cartfiles.0, to: baseUrl)
                        if let resolvedCartfile = cartfiles.1 {
                            _ = self.writeResolvedCartfile(resolvedCartfile, to: baseUrl)
                        }
                        return cartfileURL
                    }.map { cartfileURL -> URL in
                        carthage.printOut(formatting.bullets + "Finished storing diagnosis info into directory: \(baseUrl.path)")
                        carthage.printOut(formatting.bullets + "Please submit the contents of this directory to the Carthage team for review")
                        return cartfileURL
                }
            } catch let error {
                if let carthageError = error as? CarthageError {
                    return SignalProducer(error: carthageError)
                } else {
                    return SignalProducer(error: CarthageError.internalError(description: error.localizedDescription))
                }
            }
        }
    }

    private func writeCartfile(_ cartfile: Cartfile, to directory: URL) -> Result<URL, CarthageError> {
        return Result(catching: { () -> (URL) in
            let cartfileURL = Cartfile.url(in: directory)
            try cartfile.description.write(to: cartfileURL, atomically: true, encoding: .utf8)
            return cartfileURL
        })
    }

    private func writeResolvedCartfile(_ cartfile: ResolvedCartfile, to directory: URL) -> Result<URL, CarthageError> {
        return Result(catching: { () -> (URL) in
            let cartfileURL = ResolvedCartfile.url(in: directory)
            try cartfile.description.write(to: cartfileURL, atomically: true, encoding: .utf8)
            return cartfileURL
        })
    }

    private func repositoryURL(for outputPath: String?) -> URL {
        let directoryURL: URL
        if let directory = outputPath {
            directoryURL = URL(fileURLWithPath: directory)
        } else {
            let uniqueDirName = ProcessInfo.processInfo.globallyUniqueString
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(uniqueDirName)
            directoryURL = tempURL
        }
        return directoryURL
    }

    private func mappings(from file: String) throws -> [Dependency: Dependency] {
        var mappings = [Dependency: Dependency]()
        let data = try String(contentsOfFile: file, encoding: .utf8)
        let lines = data.components(separatedBy: .newlines)

        var lineNumber = 1
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Ignore comment lines
            if !trimmedLine.hasPrefix("#") && !trimmedLine.isEmpty {
                let components = trimmedLine.components(separatedBy: "=")
                if components.count != 2 {
                    throw CarthageError.parseError(description: "Could not parse mapping file \(file) line #\(lineNumber): line should contain exactly one '=' sign")
                } else {
                    let keyDependency: Dependency
                    let valueDependency: Dependency
                    do {
                        keyDependency = try self.dependencyFrom(string: components[0])
                    } catch {
                        throw CarthageError.parseError(description: "Could not parse mapping file \(file) line #\(lineNumber): \(error)")
                    }
                    do {
                        valueDependency = try self.dependencyFrom(string: components[1])
                    } catch {
                        throw CarthageError.parseError(description: "Could not parse mapping file \(file) line #\(lineNumber): \(error)")
                    }
                    mappings[keyDependency] = valueDependency
                }
            }
            lineNumber += 1
        }
        return mappings
    }

    private func dependencyFrom(string: String) throws -> Dependency {
        let trimmedString = string.trimmingCharacters(in: .whitespaces)
        let scannerResult = Dependency.from(Scanner(string: trimmedString))
        switch scannerResult {
        case .success(let dependency):
            return dependency
        case .failure(let error):
            throw error
        }
    }
}
