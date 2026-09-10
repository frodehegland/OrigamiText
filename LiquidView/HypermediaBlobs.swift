import Foundation
import CryptoKit

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

    /// The bytes an account address stands for.
    static func principal(fromUID uid: String) -> Data? {
        guard let bytes = Multibase.decodeBase58btc(uid), bytes.count == 34,
              bytes.prefix(2) == principalPrefix else { return nil }
        return bytes
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
