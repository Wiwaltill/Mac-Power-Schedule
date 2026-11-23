import Foundation
import CryptoKit

public enum ServiceUpdate {
    public static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func needsReplacement(installed: URL, bundled: URL) throws -> Bool {
        try digest(of: installed) != digest(of: bundled)
    }
}

public struct ServiceRuntime: Codable, Sendable {
    public let processID: Int32
    public let executableDigest: String
    public init(processID: Int32, executableDigest: String) {
        self.processID = processID
        self.executableDigest = executableDigest
    }
}
