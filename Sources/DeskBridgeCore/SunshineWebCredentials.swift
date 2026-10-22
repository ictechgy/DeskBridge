// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// Pinned Sunshine credential-file format, generated before a listener can open.
/// Only salted hashes are persisted. This is independent of streaming/PIN trust.
public enum SunshineWebCredentials {
    public struct Failure: Error, LocalizedError {
        public var errorDescription: String? { "최초 공유 전에 웹 관리자 이름과 16~128바이트 비밀번호를 입력하세요. 기존 계정 파일이 손상됐다면 설정을 백업하고 확인하세요. 자동 초기화하지 않습니다." }
    }
    public static func encode(username: String, password: String, salt: String) throws -> Data {
        guard (1...64).contains(username.utf8.count), username.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              (16...128).contains(password.utf8.count), !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (16...128).contains(salt.utf8.count), salt.utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure() }
        // util::hex in the pinned upstream reverses digest bytes and uses uppercase.
        let hash = SHA256.hash(data: Data((password + salt).utf8)).reversed().map { String(format: "%02X", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: ["username": username, "password": hash, "salt": salt], options: [.sortedKeys])
    }
    public static func validate(_ data: Data) throws {
        guard data.count <= 8192, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = value["username"] as? String, !username.isEmpty, username.utf8.count <= 256,
              let salt = value["salt"] as? String, !salt.isEmpty, salt.utf8.count <= 256,
              let hash = value["password"] as? String, hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { throw Failure() }
    }
}
