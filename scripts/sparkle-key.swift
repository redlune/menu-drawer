import CryptoKit
import Darwin
import Foundation

enum KeyError: Error {
    case invalidArguments
    case invalidSeed
    case cannotCreatePrivateFile
}

func key() throws -> Curve25519.Signing.PrivateKey {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["public"]:
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        guard let seed = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32
        else { throw KeyError.invalidSeed }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    case let arguments where arguments.count == 2 && arguments[0] == "generate":
        let path = arguments[1]
        let key = Curve25519.Signing.PrivateKey()
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw KeyError.cannotCreatePrivateFile }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: Data(key.rawRepresentation.base64EncodedString().utf8))
            try file.close()
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        return key
    default:
        throw KeyError.invalidArguments
    }
}

do {
    let signingKey = try key()
    print(signingKey.publicKey.rawRepresentation.base64EncodedString())
} catch {
    fputs("Use sparkle-key.swift public with a 32-byte base64 seed on stdin, or generate with a new private file path.\n", stderr)
    exit(1)
}
