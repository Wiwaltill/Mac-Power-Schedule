import Foundation
import CryptoKit

func fail() -> Never {
    fputs("Sparkle signing key does not match the public key embedded in the app.\n", stderr)
    exit(1)
}
guard CommandLine.arguments.count == 2,
      let encoded = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8),
      let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
      let expected = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else { fail() }
guard key.publicKey.rawRepresentation.base64EncodedString() == expected.trimmingCharacters(in: .whitespacesAndNewlines) else { fail() }
print("Sparkle signing key matches the embedded public key.")
