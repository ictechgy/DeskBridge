// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Open before inspecting to avoid path races; nonblocking open also rejects FIFOs without waiting for a writer.
public enum BoundedRegularFile {
    public enum Failure: Error, LocalizedError {
        case missing, invalidFile, tooLarge, unreadable
        public var errorDescription: String? {
            switch self {
            case .missing: "선택한 파일이 없습니다. 파일 위치를 확인하세요."
            case .invalidFile: "일반 파일을 선택하세요. 폴더·링크·특수 파일은 사용할 수 없습니다."
            case .tooLarge: "선택한 파일이 허용된 크기를 넘었습니다."
            case .unreadable: "선택한 파일을 읽지 못했습니다. 파일과 읽기 권한을 확인하세요."
            }
        }
    }
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, !url.path.contains("\0"), maximumBytes > 0, maximumBytes <= 64 * 1024 * 1024 else { throw Failure.invalidFile }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw Failure.missing }
            throw Failure.unreadable
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size >= 0 else {
            throw Failure.invalidFile
        }
        guard attributes.st_size <= Int64(maximumBytes) else { throw Failure.tooLarge }
        var result = Data(), buffer = [UInt8](repeating: 0, count: min(65_536, maximumBytes + 1))
        while result.count <= maximumBytes {
            let limit = min(buffer.count, maximumBytes + 1 - result.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, limit) }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.unreadable
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw Failure.tooLarge
    }
}
