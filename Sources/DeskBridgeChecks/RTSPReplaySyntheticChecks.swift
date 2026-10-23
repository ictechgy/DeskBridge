// SPDX-License-Identifier: GPL-3.0-only
// Compile with the complete production engine using scripts/tests/test_rtsp_replay.py.
// The harness calls the same decodeResponse entry point as transact, with fresh in-memory
// AES-GCM frames. It never starts a handshake, transport, UI, identity store or socket.
#if DESKBRIDGE_RTSP_REPLAY_SYNTHETIC_CHECKS
import Foundation
import CryptoKit
import Network
import Darwin

private struct RTSPReplayCheckFailure: Error { let message: String }
private actor RTSPExchangeCounter {
    private(set) var calls = 0
    func exchange(_ bytes: Data) throws -> Data {
        calls += 1
        if calls == 1 { throw RtspError.connectionNotReady("synthetic refused before ready") }
        return bytes
    }
}

@main
private struct RTSPReplaySyntheticChecks {
    static let key = [UInt8](0..<16)

    static func main() async throws {
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw RTSPReplayCheckFailure(message: message) }; checks += 1
        }
        func rejects(_ client: RtspClient, _ frame: Data, _ request: RtspMessage, _ message: String) throws {
            let before = client.lastHostEncryptionSeq
            var rejected = false
            do { _ = try client.decodeResponse(frame, for: request) } catch { rejected = true }
            try require(rejected && client.lastHostEncryptionSeq == before, message)
        }
        let client = makeClient()
        let first = client.makeRequest("OPTIONS", "rtspenc://192.0.2.1:48010")
        _ = try client.sealRtsp(first.serialize())
        let accepted = try frame(sequence: 41, cseq: "1")
        try require(try client.decodeResponse(accepted, for: first).statusCode == 200,
                    "independent host sequence must not equal outbound request counter")
        try require(client.lastHostEncryptionSeq == 41 && client.encryptionSeq == 1,
                    "accepted response must commit only the host counter")
        try rejects(client, accepted, first, "exact authenticated replay was accepted")

        let second = client.makeRequest("DESCRIBE", "rtspenc://192.0.2.1:48010")
        try rejects(client, try frame(sequence: 40, cseq: "2"), second, "older authenticated sequence was accepted")
        try require(try client.decodeResponse(try frame(sequence: 44, cseq: "2"), for: second).statusCode == 200,
                    "a skipped independent host sequence must remain compatible with retries")
        let third = client.makeRequest("SETUP", "streamid=audio/0/0")
        var badTag = try frame(sequence: 200, cseq: "3"); badTag[8] ^= 0x80
        try rejects(client, badTag, third, "invalid AEAD tag consumed sequence state")
        var tamperedSequence = try frame(sequence: 45, cseq: "3"); tamperedSequence[7] ^= 1
        try rejects(client, tamperedSequence, third, "unauthenticated header sequence consumed state")
        try rejects(client, try frame(sequence: 400, cseq: "99"), third, "wrong CSeq consumed sequence state")
        try rejects(client, try frame(sequence: 400, plaintext: Data("RTSP/1.0 200 OK\r\n\r\n".utf8)), third,
                    "missing CSeq consumed sequence state")
        try require(try client.decodeResponse(try frame(sequence: 45, cseq: "3"), for: third).statusCode == 200,
                    "rejected higher sequences must not block the actual response")

        let fourth = client.makeRequest("SETUP", "streamid=video/0/0")
        for value in ["+4", "-4", "4 0", "4\t0", "٤", "", "0", "18446744073709551616"] {
            try rejects(client, try frame(sequence: 500, cseq: value), fourth, "malformed CSeq accepted: \(value)")
        }
        for headers in ["CSeq: 4\r\nCSeq: 4", "CSeq: 4\r\ncseq: 4", "CSeq: 4\r\nCSeq: 9", "CSeq : 4"] {
            try rejects(client, try frame(sequence: 500, plaintext: Data("RTSP/1.0 200 OK\r\n\(headers)\r\n\r\n".utf8)),
                        fourth, "ambiguous CSeq headers were accepted")
        }
        for message in ["garbage", "RTSP/1.0 200 OK\r\nCSeq: 4", "HTTP/1.1 200 OK\r\nCSeq: 4\r\n\r\n",
                        "RTSP/1.0 invalid OK\r\nCSeq: 4\r\n\r\n"] {
            try rejects(client, try frame(sequence: 500, plaintext: Data(message.utf8)), fourth,
                        "malformed RTSP response consumed sequence state")
        }
        try require(try client.decodeResponse(try frame(sequence: 46, plaintext: Data("RTSP/1.0 200 OK\r\ncseq: \t0004\t\r\n\r\n".utf8)),
                                             for: fourth).statusCode == 200,
                    "legal case-insensitive CSeq, horizontal whitespace and leading zeroes must bind numerically")

        let fifth = client.makeRequest("SETUP", "streamid=control/13/0")
        let validFifth = try frame(sequence: 47, cseq: "5")
        for length in [0, 1, 8, 23, 24] {
            try rejects(client, Data(validFifth.prefix(length)), fifth, "short frame consumed sequence state")
        }
        try rejects(client, validFifth + Data([0]), fifth, "excess frame bytes were accepted")
        try rejects(client, Data(validFifth.dropLast()), fifth, "truncated ciphertext was accepted")
        var plaintextFlag = validFifth; plaintextFlag[0] &= 0x7f
        try rejects(client, plaintextFlag, fifth, "unencrypted header flag was accepted")
        try rejects(client, Data("RTSP/1.0 200 OK\r\nCSeq: 5\r\n\r\n".utf8), fifth,
                    "encrypted connection accepted plaintext fallback")
        try require(try client.decodeResponse(validFifth, for: fifth).statusCode == 200,
                    "malformed frames must not prevent a later authenticated response")
        var badRequest = fifth; badRequest.headers.append(("cseq", "5"))
        try rejects(client, try frame(sequence: 600, cseq: "5"), badRequest, "ambiguous request CSeq was accepted")

        let wrapClient = makeClient()
        let wrapRequest = wrapClient.makeRequest("OPTIONS", "/")
        _ = try wrapClient.decodeResponse(try frame(sequence: .max, cseq: "1"), for: wrapRequest)
        try require(wrapClient.lastHostEncryptionSeq == .max, "maximum host sequence was rejected")
        try rejects(wrapClient, try frame(sequence: 0, cseq: "1"), wrapRequest, "host sequence wrap was accepted")
        let freshClient = makeClient()
        try require(freshClient.lastHostEncryptionSeq == nil, "a fresh RTSP instance retained another attempt's counter")
        _ = try freshClient.decodeResponse(accepted, for: first)
        try require(freshClient.lastHostEncryptionSeq == 41, "a fresh attempt must own independent replay state")
        // Exercise the actual retry loop with inert exchanges: only pre-ready failures
        // may resend. A post-send failure can mean the host processed the transaction.
        let exchange = RTSPExchangeCounter()
        let fixture = Data([1, 2, 3])
        let retried = try await makeClient().sendAndReceive(fixture) { try await exchange.exchange($0) }
        let exchangeCalls = await exchange.calls
        try require(retried == fixture && exchangeCalls == 2, "pre-ready failure did not retry once")
        for reason in ["send: synthetic failure", "recv: synthetic failure"] {
            let calls = AtomicCounter()
            var originalFailure = false
            do {
                _ = try await makeClient().sendAndReceive(fixture) { _ in
                    calls.increment()
                    throw RtspError.transportFailure(reason)
                }
            } catch RtspError.transportFailure(let received) { originalFailure = received == reason }
            try require(originalFailure && calls.value == 1, "post-ready failure was retried or rewritten")
        }
        let cancelled = makeClient(); cancelled.interrupt()
        let calls = AtomicCounter()
        var interrupted = false
        do { _ = try await cancelled.sendAndReceive(fixture) { value in calls.increment(); return value } }
        catch RtspError.interrupted { interrupted = true }
        try require(interrupted && calls.value == 0, "interrupted RTSP invoked exchange")
        print("RTSP replay and CSeq synthetic checks: \(checks)")
    }

    static func makeClient() -> RtspClient {
        let config = BackendStreamConfig(width: 1920, height: 1080, fps: 60, bitrate: 20000, packetSize: 1024,
            streamingRemotely: 0, audioConfiguration: 2, supportedVideoFormats: 1, clientRefreshRateX100: 6000,
            colorSpace: 0, colorRange: 0, encryptionFlags: 0, remoteInputAesKey: key,
            remoteInputAesIv: [UInt8](repeating: 0, count: 16))
        return RtspClient(host: NWEndpoint.Host("192.0.2.1"), rtspPort: 48010, rtspTargetUrl: "rtspenc://192.0.2.1:48010",
                          urlAddr: "192.0.2.1", urlSafeAddr: "192.0.2.1", addrFamilyToken: "IP4", config: config,
                          serverCodecModeRaw: 0)
    }

    static func frame(sequence: UInt32, cseq: String) throws -> Data {
        try frame(sequence: sequence, plaintext: Data("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\r\n".utf8))
    }

    static func frame(sequence: UInt32, plaintext: Data) throws -> Data {
        // Real host-originated AES-GCM; header format and nonce follow pinned Sunshine rtsp.cpp.
        var iv = [UInt8](repeating: 0, count: 12)
        for index in 0..<4 { iv[index] = UInt8((sequence >> (index * 8)) & 0xff) }
        iv[10] = 0x48; iv[11] = 0x52
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: Data(key)), nonce: AES.GCM.Nonce(data: Data(iv)))
        var result = Data(RtspClient.beBytes(RtspClient.encryptedRtspBit | UInt32(plaintext.count)))
        result.append(contentsOf: RtspClient.beBytes(sequence))
        result.append(sealed.tag); result.append(sealed.ciphertext)
        return result
    }
}
#endif
