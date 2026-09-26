import Foundation
import CryptoKit
// PBKDF2 for the BIP-39 phrase: CryptoKit has no key-stretching, and the
// standard's parameters are fixed, so CommonCrypto does that one step.
import CommonCrypto

// Writing to the Hypermedia protocol.
//
// Everything a space stores is a signed blob: DAG-CBOR bytes carrying the
// signer's public key and an Ed25519 signature over the same bytes with
// the signature zeroed. This file has just enough of that machinery for
// Origami Text to introduce a person (a Profile blob) and to speak on a
// document (a Comment blob). It mirrors the protocol's reference client
// (`@seed-hypermedia/client`, blobs.ts and comment.ts) byte for byte.

// MARK: - DAG-CBOR

/// The subset of CBOR the protocol's blobs use, encoded canonically the
/// way DAG-CBOR demands: map keys sorted shortest first, then bytewise;
/// integers in their shortest form; CIDs as tag 42 over their bytes.
nonisolated indirect enum CBORValue {
    case uint(UInt64)
    case bytes(Data)
    case string(String)
    case array([CBORValue])
    case map([(String, CBORValue)])
    case bool(Bool)
    case null
    case cid(Data)

    var encoded: Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case .uint(let n):
            Self.head(major: 0, value: n, into: &out)
        case .bytes(let d):
            Self.head(major: 2, value: UInt64(d.count), into: &out)
            out.append(d)
        case .string(let s):
            let utf8 = Data(s.utf8)
            Self.head(major: 3, value: UInt64(utf8.count), into: &out)
            out.append(utf8)
        case .array(let items):
            Self.head(major: 4, value: UInt64(items.count), into: &out)
            for item in items { item.encode(into: &out) }
        case .map(let pairs):
            let sorted = pairs.sorted { a, b in
                let ka = Array(a.0.utf8), kb = Array(b.0.utf8)
                if ka.count != kb.count { return ka.count < kb.count }
                return ka.lexicographicallyPrecedes(kb)
            }
            Self.head(major: 5, value: UInt64(sorted.count), into: &out)
            for (key, value) in sorted {
                CBORValue.string(key).encode(into: &out)
                value.encode(into: &out)
            }
        case .bool(let b):
            out.append(b ? 0xf5 : 0xf4)
        case .null:
            out.append(0xf6)
        case .cid(let cidBytes):
            out.append(contentsOf: [0xd8, 0x2a])          // tag 42
            var payload = Data([0x00])                    // multibase identity prefix
            payload.append(cidBytes)
            Self.head(major: 2, value: UInt64(payload.count), into: &out)
            out.append(payload)
        }
    }

    private static func head(major: UInt8, value: UInt64, into out: inout Data) {
        let m = major << 5
        switch value {
        case 0..<24:
            out.append(m | UInt8(value))
        case 24...0xff:
            out.append(m | 24); out.append(UInt8(value))
        case 0x100...0xffff:
            out.append(m | 25)
            out.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
        case 0x10000...0xffff_ffff:
            out.append(m | 26)
            out.append(contentsOf: (0..<4).reversed().map { UInt8((value >> (8 * $0)) & 0xff) })
        default:
            out.append(m | 27)
            out.append(contentsOf: (0..<8).reversed().map { UInt8((value >> (8 * $0)) & 0xff) })
        }
    }
}

// MARK: - Multibase and CIDs

nonisolated enum Multibase {
    private static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// Bitcoin-style base58, with the multibase `z` prefix.
    static func base58btc(_ data: Data) -> String {
        var digits: [Int] = [0]
        for byte in data {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += digits[i] << 8
                digits[i] = carry % 58
                carry /= 58
            }
            while carry > 0 { digits.append(carry % 58); carry /= 58 }
        }
        var result = "z"
        for byte in data { if byte == 0 { result.append("1") } else { break } }
        for d in digits.reversed() { result.append(base58Alphabet[d]) }
        return result
    }

    static func decodeBase58btc(_ string: String) -> Data? {
        guard string.hasPrefix("z") else { return nil }
        var bytes: [UInt8] = [0]
        for ch in string.dropFirst() {
            guard let value = base58Alphabet.firstIndex(of: ch) else { return nil }
            var carry = value
            for i in 0..<bytes.count {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 { bytes.append(UInt8(carry & 0xff)); carry >>= 8 }
        }
        for ch in string.dropFirst() { if ch == "1" { bytes.append(0) } else { break } }
        return Data(bytes.reversed())
    }

    /// RFC 4648 base32, lower case, unpadded, with the multibase `b` prefix.
    static func base32(_ data: Data) -> String {
        var result = "b"
        var buffer: UInt64 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(base32Alphabet[Int((buffer >> UInt64(bits)) & 0x1f)])
            }
        }
        if bits > 0 { result.append(base32Alphabet[Int((buffer << UInt64(5 - bits)) & 0x1f)]) }
        return result
    }

    static func decodeBase32(_ string: String) -> Data? {
        guard string.hasPrefix("b") else { return nil }
        var out = Data()
        var buffer: UInt64 = 0
        var bits = 0
        for ch in string.dropFirst() {
            guard let value = base32Alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt64(bits)) & 0xff))
            }
        }
        return out
    }
}

nonisolated enum CID {
    /// A CIDv1 over DAG-CBOR bytes with SHA-256: what the protocol names
    /// every blob by.
    static func dagCBOR(_ data: Data) -> Data {
        var cid = Data([0x01, 0x71, 0x12, 0x20])   // v1, dag-cbor, sha2-256, 32 bytes
        cid.append(contentsOf: SHA256.hash(data: data))
        return cid
    }

    static func string(_ cid: Data) -> String { Multibase.base32(cid) }

    /// `bafy…` → bytes. Only the base32 multibase form is in use.
    static func parse(_ string: String) -> Data? {
        Multibase.decodeBase32(string.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Identity

/// The person's signing key: an Ed25519 seed, kept in the Keychain. The
/// public half, prefixed with the Ed25519 multicodec, is the principal
/// whose base58 form is the account address every space knows them by.
nonisolated struct HypermediaIdentity: Sendable {
    let seed: Data
    let principal: Data
    /// `z6Mk…` — the account uid.
    let uid: String

    static let principalPrefix = Data([0xed, 0x01])

    init(seed: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.seed = seed
        var principal = Self.principalPrefix
        principal.append(key.publicKey.rawRepresentation)
        self.principal = principal
        self.uid = Multibase.base58btc(principal)
    }

    static func generate() -> HypermediaIdentity {
        // A fresh key's raw representation is always valid seed material.
        try! HypermediaIdentity(seed: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    func sign(_ data: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: data)
    }

    /// The full 64-byte Ed25519 private key: the signing seed, then its
    /// public half. The form that proves itself when read back, and the
    /// one to hand another app — an account that cannot leave the app
    /// that made it is not an account, it is a hostage.
    var privateKey: Data { seed + principal.dropFirst(2) }

    /// Lowercase hex, the least ambiguous way to write a key down.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes an account address stands for.
    static func principal(fromUID uid: String) -> Data? {
        guard let bytes = Multibase.decodeBase58btc(uid), bytes.count == 34,
              bytes.prefix(2) == principalPrefix else { return nil }
        return bytes
    }
}

// MARK: - Signing in to an account that already exists

/// Bringing an existing Hypermedia account into this app.
///
/// An account IS its key, so signing in means supplying the key — as the
/// twelve-word secret recovery phrase the Seed app hands out, or as the
/// raw 32-byte signing seed.
///
/// The phrase is BIP-39: the words are stretched with PBKDF2-HMAC-SHA512,
/// 2048 rounds, salted "mnemonic", exactly as that standard says. What
/// this code could NOT establish is the last step — whether Seed takes
/// the Ed25519 seed as the first 32 bytes of those 64, or as the
/// SLIP-0010 master key derived from them. The two give different
/// accounts, and guessing would silently sign a person in as somebody
/// they are not.
///
/// So both are derived and both addresses are shown, and the reader
/// confirms which is theirs before anything is saved (Seed's own
/// `seed key derive "<words>"` prints the address to compare, and a
/// profile on hyper.media shows it too). When the answer is known for
/// certain, drop the other candidate and this comment with it.
nonisolated enum HypermediaSignIn {

    /// One reading of a phrase: how the seed was derived, and the account
    /// address that reading produces.
    struct Candidate: Identifiable, Sendable {
        /// "First 32 bytes" / "SLIP-0010" / "Raw key".
        let label: String
        let detail: String
        let seed: Data
        let uid: String
        var id: String { label + uid }
    }

    /// Every account the given key or words could mean, most likely
    /// first. Empty when the input is neither a readable key nor a
    /// plausible phrase.
    static func candidates(for input: String) -> [Candidate] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // A private key is the direct answer, and needs no guessing: one
        // key, one account. It stands alone.
        if let key = privateKey(from: trimmed), let id = identity(from: key.seed) {
            return [Candidate(label: "Private key", detail: key.how,
                              seed: key.seed, uid: id.uid)]
        }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map {
            $0.lowercased()
        }
        guard words.count >= 12 else { return [] }
        let phrase = words.joined(separator: " ")
        guard let bip39 = bip39Seed(phrase: phrase) else { return [] }

        var found: [Candidate] = []
        let firstHalf = bip39.prefix(32)
        if let id = identity(from: Data(firstHalf)) {
            found.append(Candidate(
                label: "First 32 bytes",
                detail: "The seed's first half used directly as the signing key.",
                seed: Data(firstHalf), uid: id.uid))
        }
        let master = slip10MasterKey(seed: bip39)
        if let id = identity(from: master), master != Data(firstHalf) {
            found.append(Candidate(
                label: "SLIP-0010",
                detail: "The standard Ed25519 master key derived from the seed.",
                seed: master, uid: id.uid))
        }
        return found
    }

    private static func identity(from seed: Data) -> HypermediaIdentity? {
        try? HypermediaIdentity(seed: seed)
    }

    /// A private key as Seed might hand it over, in whatever shape it
    /// arrives: hex (with or without `0x`), base64, base64url, or
    /// base58 (bare, or multibase `z`). The bytes inside may be the bare
    /// 32-byte signing seed, the 64-byte Ed25519 private key (seed then
    /// public half), a libp2p protobuf-wrapped key, or a multicodec
    /// `ed25519-priv` key. Whitespace and newlines are ignored, so a
    /// pasted line wraps harmlessly.
    ///
    /// A 64-byte key proves itself: its second half must be the public
    /// key its first half derives, and when that holds the account is
    /// certain rather than merely plausible.
    static func privateKey(from text: String) -> (seed: Data, how: String)? {
        for bytes in decodings(of: text) {
            if let found = seedInside(bytes) { return found }
        }
        return nil
    }

    /// The key inside a file Seed wrote — the JSON export, or any file
    /// whose text is the key.
    ///
    /// The JSON's shape is not assumed: every string in it is tried, and
    /// every array of numbers that could be key bytes, with the fields
    /// whose names suggest a key tried first. What comes back is the
    /// text that was found, so it runs through exactly the same reading
    /// (and the same self-check) as a pasted key — and where in the file
    /// it came from, to say so.
    static func keyText(inFile data: Data) -> (text: String, how: String)? {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            var strings: [(path: String, value: String)] = []
            var byteArrays: [(path: String, value: Data)] = []
            collect(json, at: "", strings: &strings, byteArrays: &byteArrays)
            // A field that names itself is likelier than one that does not.
            let telling = ["privatekey", "private_key", "secretkey", "secret_key",
                           "signingkey", "signing_key", "secret", "seed", "key"]
            func rank(_ path: String) -> Int {
                let lower = path.lowercased()
                for (index, name) in telling.enumerated() where lower.contains(name) {
                    return index
                }
                return telling.count
            }
            for entry in strings.sorted(by: { rank($0.path) < rank($1.path) }) {
                if privateKey(from: entry.value) != nil {
                    return (entry.value, entry.path.isEmpty
                            ? "Read from the file."
                            : "Read from the file's \(entry.path).")
                }
            }
            for entry in byteArrays.sorted(by: { rank($0.path) < rank($1.path) }) {
                let hex = HypermediaIdentity.hex(entry.value)
                if privateKey(from: hex) != nil {
                    return (hex, entry.path.isEmpty
                            ? "Read from the file's bytes."
                            : "Read from the file's \(entry.path) bytes.")
                }
            }
            return nil
        }
        // Not JSON: a .key or .txt holding the key itself.
        guard let text = String(data: data, encoding: .utf8),
              privateKey(from: text) != nil else { return nil }
        return (text, "Read from the file.")
    }

    /// Walks a decoded JSON tree, gathering every string and every array
    /// of bytes, each with the dotted path it was found at.
    private static func collect(_ value: Any, at path: String,
                                strings: inout [(path: String, value: String)],
                                byteArrays: inout [(path: String, value: Data)]) {
        switch value {
        case let text as String:
            strings.append((path, text))
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                collect(child, at: path.isEmpty ? key : "\(path).\(key)",
                        strings: &strings, byteArrays: &byteArrays)
            }
        case let array as [Any]:
            // An array of small whole numbers is very likely key bytes.
            let numbers = array.compactMap { $0 as? NSNumber }
            if numbers.count == array.count,
               array.count == 32 || array.count == 64 || array.count == 68,
               numbers.allSatisfy({ $0.intValue >= 0 && $0.intValue <= 255 }) {
                byteArrays.append((path, Data(numbers.map { UInt8($0.intValue) })))
                return
            }
            for (index, child) in array.enumerated() {
                collect(child, at: "\(path)[\(index)]",
                        strings: &strings, byteArrays: &byteArrays)
            }
        default:
            break
        }
    }

    /// Every byte string the text could be, cheapest reading first.
    private static func decodings(of text: String) -> [Data] {
        let compact = text.filter { !$0.isWhitespace && $0 != "\"" }
        guard !compact.isEmpty else { return [] }
        var found: [Data] = []
        func add(_ data: Data?) {
            guard let data, !data.isEmpty, !found.contains(data) else { return }
            found.append(data)
        }
        let hexBody = compact.hasPrefix("0x") || compact.hasPrefix("0X")
            ? String(compact.dropFirst(2)) : compact
        if hexBody.count % 2 == 0, hexBody.count >= 64, hexBody.allSatisfy(\.isHexDigit) {
            var bytes = Data()
            var index = hexBody.startIndex
            while index < hexBody.endIndex {
                let next = hexBody.index(index, offsetBy: 2)
                guard let byte = UInt8(hexBody[index..<next], radix: 16) else { bytes = Data(); break }
                bytes.append(byte)
                index = next
            }
            add(bytes)
        }
        add(Data(base64Encoded: compact))
        // base64url, as tools that put keys in URLs emit it.
        var url = compact.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while url.count % 4 != 0 { url.append("=") }
        add(Data(base64Encoded: url))
        add(Multibase.decodeBase58btc(compact))
        add(Multibase.decodeBase58btc("z" + compact))
        return found
    }

    /// The 32-byte signing seed inside a byte string, and how it was
    /// read — unwrapping the envelopes a key travels in.
    private static func seedInside(_ bytes: Data) -> (seed: Data, how: String)? {
        // libp2p's protobuf: field 1 = key type (1 = Ed25519), field 2 =
        // the key bytes. This is how IPFS-descended tools serialise one.
        if bytes.count > 4, bytes[bytes.startIndex] == 0x08,
           bytes[bytes.startIndex + 1] == 0x01,
           bytes[bytes.startIndex + 2] == 0x12 {
            let length = Int(bytes[bytes.startIndex + 3])
            let body = bytes.dropFirst(4)
            if body.count >= length, length == 64 || length == 32 {
                let inner = Data(body.prefix(length))
                if let found = seedInside(inner) {
                    return (found.seed, "A libp2p-wrapped Ed25519 private key. " + found.how)
                }
            }
        }
        // multicodec ed25519-priv (0x1300, varint 0x80 0x26).
        if bytes.count == 34, bytes[bytes.startIndex] == 0x80,
           bytes[bytes.startIndex + 1] == 0x26 {
            return (Data(bytes.dropFirst(2)),
                    "A multicodec ed25519-priv key.")
        }
        // The full Ed25519 private key: seed, then the public half. It
        // checks itself.
        if bytes.count == 64 {
            let seed = Data(bytes.prefix(32))
            let tail = Data(bytes.suffix(32))
            if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
               key.publicKey.rawRepresentation == tail {
                return (seed, "A 64-byte Ed25519 private key whose public half matches — this is certainly the right account.")
            }
        }
        if bytes.count == 32 {
            return (bytes, "A 32-byte signing seed, as given.")
        }
        return nil
    }

    /// BIP-39: PBKDF2-HMAC-SHA512 over the words, salted "mnemonic",
    /// 2048 rounds, 64 bytes out. The words are not checksum-checked —
    /// the derived address is the check that matters, and it is shown.
    static func bip39Seed(phrase: String, passphrase: String = "") -> Data? {
        let password = Array(phrase.decomposedStringWithCompatibilityMapping.utf8)
        let salt = Array(("mnemonic" + passphrase)
            .decomposedStringWithCompatibilityMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 64)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password.withUnsafeBufferPointer { $0.baseAddress?.withMemoryRebound(
                to: CChar.self, capacity: password.count) { $0 } },
            password.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
            2048,
            &derived, derived.count)
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    /// SLIP-0010's master key for Ed25519: HMAC-SHA512 of the seed under
    /// the key "ed25519 seed", left half.
    static func slip10MasterKey(seed: Data) -> Data {
        let key = SymmetricKey(data: Data("ed25519 seed".utf8))
        let mac = HMAC<SHA512>.authenticationCode(for: seed, using: key)
        return Data(mac).prefix(32)
    }
}

// MARK: - Blobs

nonisolated enum HypermediaBlobs {

    struct Blob: Sendable {
        let data: Data
        /// The blob's CID string; sent along so the space stores it under
        /// the name the client already knows.
        let cid: String
    }

    /// Signs a blob: encodes it with a zeroed signature, signs those bytes,
    /// then encodes again with the real signature in place.
    static func sign(_ fields: [(String, CBORValue)], with identity: HypermediaIdentity) throws -> Data {
        var unsigned = fields.filter { $0.0 != "sig" && $0.0 != "signer" }
        unsigned.append(("signer", .bytes(identity.principal)))
        unsigned.append(("sig", .bytes(Data(count: 64))))
        let signature = try identity.sign(CBORValue.map(unsigned).encoded)
        var signed = unsigned.filter { $0.0 != "sig" }
        signed.append(("sig", .bytes(signature)))
        return CBORValue.map(signed).encoded
    }

    /// The bytes that were signed: the blob with its signature zeroed.
    /// For checking a blob against its signer.
    static func unsignedForm(_ fields: [(String, CBORValue)], identity: HypermediaIdentity) -> Data {
        var unsigned = fields.filter { $0.0 != "sig" && $0.0 != "signer" }
        unsigned.append(("signer", .bytes(identity.principal)))
        unsigned.append(("sig", .bytes(Data(count: 64))))
        return CBORValue.map(unsigned).encoded
    }

    // MARK: Profile

    /// A Profile blob: how a key says what to call it. Publishing one to a
    /// space is what makes the account visible there.
    static func profile(name: String, identity: HypermediaIdentity,
                        timestamp: UInt64 = UInt64(Date.now.timeIntervalSince1970 * 1000)) throws -> Blob {
        let fields: [(String, CBORValue)] = [
            ("type", .string("Profile")),
            ("name", .string(name)),
            ("ts", .uint(timestamp)),
        ]
        let data = try sign(fields, with: identity)
        return Blob(data: data, cid: CID.string(CID.dagCBOR(data)))
    }

    // MARK: Comment

    /// A Comment blob on one version of a document. `replyTo` names the
    /// parent comment and the thread's root by their version CIDs.
    static func comment(text: String, on address: HypermediaAddress, documentVersion: String,
                        replyTo: (parent: String, root: String)? = nil,
                        identity: HypermediaIdentity,
                        timestamp: UInt64 = UInt64(Date.now.timeIntervalSince1970 * 1000),
                        blockIDs: [String]? = nil) throws -> Blob {
        guard let space = HypermediaIdentity.principal(fromUID: address.uid) else {
            throw HypermediaError.invalidAddress
        }
        let versions = documentVersion.split(separator: ".").map(String.init)
        let versionCIDs = try versions.map { v -> CBORValue in
            guard let bytes = CID.parse(v) else { throw HypermediaError.decodingFailed("bad version \(v)") }
            return .cid(bytes)
        }
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let body: [CBORValue] = paragraphs.enumerated().map { i, paragraph in
            .map([
                ("id", .string(blockIDs?[safe: i] ?? randomBlockID())),
                ("type", .string("Paragraph")),
                ("text", .string(paragraph)),
                ("annotations", .array([])),
                ("children", .array([])),
            ])
        }
        var fields: [(String, CBORValue)] = [
            ("type", .string("Comment")),
            ("body", .array(body)),
            ("space", .bytes(space)),
            ("path", .string(address.path.isEmpty ? "" : "/" + address.path.joined(separator: "/"))),
            ("version", .array(versionCIDs)),
            ("ts", .uint(timestamp)),
        ]
        if let replyTo {
            guard let parent = CID.parse(replyTo.parent), let root = CID.parse(replyTo.root) else {
                throw HypermediaError.decodingFailed("bad comment version")
            }
            fields.append(("replyParent", .cid(parent)))
            fields.append(("threadRoot", .cid(root)))
        }
        let data = try sign(fields, with: identity)
        return Blob(data: data, cid: CID.string(CID.dagCBOR(data)))
    }

    /// The record id a space files a comment under: the signer's address,
    /// then a base58 id built from the timestamp and the blob's hash.
    static func commentRecordID(data: Data, identity: HypermediaIdentity, timestamp: UInt64) -> String {
        var tsid = Data((0..<6).reversed().map { UInt8((timestamp >> (8 * UInt64($0))) & 0xff) })
        tsid.append(contentsOf: Data(SHA256.hash(data: data)).prefix(4))
        return "\(identity.uid)/\(Multibase.base58btc(tsid))"
    }

    static func randomBlockID() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    // MARK: Publishing

    /// Hands blobs to a space: one CBOR-encoded POST, the space stores
    /// and indexes them.
    static func publish(_ blobs: [Blob], to origin: URL) async throws {
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        comps?.path = "/api/PublishBlobs"
        guard let url = comps?.url else { throw HypermediaError.invalidAddress }
        let body = CBORValue.map([
            ("blobs", .array(blobs.map { .map([("cid", .string($0.cid)), ("data", .bytes($0.data))]) })),
        ]).encoded
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/cbor", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw HypermediaError.serverError(message.isEmpty ? "HTTP \(http.statusCode)" : message)
        }
    }
}

nonisolated private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
