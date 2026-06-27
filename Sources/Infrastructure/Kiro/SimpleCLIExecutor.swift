import Foundation
import Domain

/// Simple CLI executor that uses Process directly without PTY
public struct SimpleCLIExecutor: CLIExecutor {
    public init() {}
    
    public func locate(_ binary: String) -> String? {
        BinaryLocator.which(binary)
    }
    
    public func execute(
        binary: String,
        args: [String],
        input: String?,
        timeout: TimeInterval,
        workingDirectory: URL?,
        autoResponses: [String: String],
        environment: [String: String]? = nil
    ) throws -> CLIResult {
        guard let binaryPath = locate(binary) else {
            throw ProbeError.cliNotFound(binary)
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
        task.arguments = args
        
        if let workingDirectory {
            task.currentDirectoryURL = workingDirectory
        }
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.environment = environment
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        try task.run()
        
        // Send input if provided
        if let input, let data = input.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()
        
        // Read output asynchronously to avoid deadlock
        var outputData = Data()
        var errorData = Data()
        
        let outputQueue = DispatchQueue(label: "kiro.cli.output")
        let errorQueue = DispatchQueue(label: "kiro.cli.error")
        
        outputQueue.async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        errorQueue.async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        
        // Wait for completion with timeout
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            usleep(100000) // 0.1 second
        }
        
        if task.isRunning {
            task.terminate()
            throw ProbeError.executionFailed("Command timed out after \(timeout) seconds")
        }
        
        // Wait for async reads to complete
        outputQueue.sync {}
        errorQueue.sync {}
        
        // Combine stdout and stderr
        var combinedData = outputData
        combinedData.append(errorData)
        let output = String(data: combinedData, encoding: .utf8) ?? ""
        
        return CLIResult(output: output, exitCode: task.terminationStatus)
    }
}
