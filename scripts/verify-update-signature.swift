import CryptoKit
import Foundation

let arguments = CommandLine.arguments
if arguments.count != 4 {
    fatalError("Usage: verify-update-signature.swift ARCHIVE PUBLIC_KEY SIGNATURE")
}
guard let publicKey = Data(base64Encoded: arguments[2]),
      let signature = Data(base64Encoded: arguments[3]) else {
    fputs("Invalid base64 public key or signature\n", stderr)
    exit(1)
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("EdDSA signature verification failed\n", stderr)
    exit(1)
}
print("EdDSA signature verified against SUPublicEDKey")
