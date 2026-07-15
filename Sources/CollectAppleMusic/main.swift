import Foundation
import Maxi80Backend

struct SearchError: Codable {
    let query: String
    let error: String
    let exitCode: Int32
}

func runCommand(arguments: [String]) -> (output: String, exitCode: Int32) {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = arguments

    do {
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        // Extract only JSON from output (starts with '{' or '[')
        let lines = output.components(separatedBy: .newlines)
        let jsonLines = lines.drop { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[")
        }

        let jsonOutput = jsonLines.joined(separator: "\n")

        if process.terminationStatus != 0 {
            return (error.isEmpty ? output : error, process.terminationStatus)
        }

        return (jsonOutput.isEmpty ? output : jsonOutput, process.terminationStatus)
    } catch {
        return ("Error: \(error)", -1)
    }
}

// Main script
let metadataFile = "metadata.txt"
let outputDir = "apple_music_results"

// Create output directory
let fileManager = FileManager.default
try fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Read metadata file
let content = try String(contentsOfFile: metadataFile, encoding: .utf8)
let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

print("Searching Apple Music for \(lines.count) tracks...")

let encoder = JSONEncoder()
encoder.outputFormatting = .prettyPrinted

for (index, line) in lines.enumerated() {
    let metadata = parseTrackMetadata(line)

    // Create search query
    var searchQuery = ""
    if let artist = metadata.artist, let title = metadata.title {
        searchQuery = "\(artist) - \(title)"
    } else if let title = metadata.title {
        searchQuery = title
    } else {
        searchQuery = line
    }

    // skip lines starting with Maxi80
    if searchQuery.starts(with: "Maxi80") {
        continue
    }

    let offset = 0
    print("[\(index + 1 + offset)/\(lines.count)] Searching: \(searchQuery)")

    let result = runCommand(arguments: [
        "run", "Maxi80CLI", "--profile", "maxi80", "--region", "eu-central-1", "search", "--types", "songs",
        searchQuery,
    ])

    let outputFile =
        "\(outputDir)/\(String(format: "%03d", index + 1 + offset))_\(searchQuery.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")).json"

    if result.exitCode == 0 {
        try result.output.write(to: URL(fileURLWithPath: outputFile), atomically: true, encoding: .utf8)
        print("  ✓ Saved to \(outputFile)")
    } else {
        print("  ✗ Error: \(result.output)")
        // Save error info
        let errorData = SearchError(
            query: searchQuery,
            error: result.output,
            exitCode: result.exitCode
        )
        let jsonData = try encoder.encode(errorData)
        try jsonData.write(to: URL(fileURLWithPath: outputFile))
    }

    // Small delay to avoid rate limiting
    Thread.sleep(forTimeInterval: 0.5)
}

print("Search complete! Results saved to \(outputDir)/")
