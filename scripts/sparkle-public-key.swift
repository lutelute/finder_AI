#!/usr/bin/env swift

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: sparkle-public-key.swift <private-key-file>\n".utf8))
    exit(64)
}

do {
    let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32 else {
        throw KeyError.invalidEncoding
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
} catch {
    FileHandle.standardError.write(Data("invalid Sparkle private key: \(error)\n".utf8))
    exit(65)
}

private enum KeyError: Error {
    case invalidEncoding
}
