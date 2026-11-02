@testable import HookFeedCore
import Darwin
import Foundation
import XCTest
@testable import HookFeedApp

final class RemoteSocketTests: XCTestCase {
    func testCapacityResponseWritesBeforeSocketEOF() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let queue = DispatchQueue(label: "socket-capacity-test")
        let connection = try RemoteSocketConnection(fd: pair[0], queue: queue)
        defer { queue.sync { connection.cancel() }; close(pair[1]) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        queue.sync { RemoteServer.rejectAtCapacity(connection, on: queue) }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(pair[1], &bytes, bytes.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        let response = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 503"), response)
        XCTAssertTrue(response.contains("Retry-After: 1"), response)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data((response.components(separatedBy: "\r\n\r\n").last ?? "").utf8)))
    }

    func testSocketReadWriteAndGracefulEOF() async throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let queue = DispatchQueue(label: "socket-test")
        let connection = try RemoteSocketConnection(fd: pair[0], queue: queue)
        defer { queue.sync { connection.cancel() }; close(pair[1]) }
        let read = expectation(description: "Pending read receives bytes")
        queue.sync {
            connection.read { data, complete, error in
                XCTAssertEqual(data, Data("hello".utf8))
                XCTAssertFalse(complete); XCTAssertNil(error); read.fulfill()
            }
        }
        _ = Data("hello".utf8).withUnsafeBytes { Darwin.send(pair[1], $0.baseAddress, $0.count, 0) }
        await fulfillment(of: [read], timeout: 2)
        let written = expectation(description: "Response and FIN written")
        connection.write(Data("reply".utf8), final: false) { error in
            XCTAssertNil(error)
            connection.write(nil, final: true) { error in XCTAssertNil(error); written.fulfill() }
        }
        await fulfillment(of: [written], timeout: 2)
        var bytes = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(recv(pair[1], &bytes, bytes.count, 0), 5)
        XCTAssertEqual(String(decoding: bytes.prefix(5), as: UTF8.self), "reply")
        XCTAssertEqual(recv(pair[1], &bytes, bytes.count, 0), 0)
    }

    func testBackpressuredWriteDeliversEveryByte() async throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        var limit: Int32 = 1024
        XCTAssertEqual(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &limit, socklen_t(MemoryLayout<Int32>.size)), 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        XCTAssertEqual(setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        let queue = DispatchQueue(label: "socket-backpressure-test")
        let connection = try RemoteSocketConnection(fd: pair[0], queue: queue)
        defer { queue.sync { connection.cancel() }; close(pair[1]) }
        let payload = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        let written = expectation(description: "Partial writes finish")
        let received = expectation(description: "Peer receives full response")
        connection.write(payload, final: false) { error in XCTAssertNil(error); written.fulfill() }
        queue.sync {} // Fill the small send buffer before the peer begins reading.
        let peer = pair[1]
        DispatchQueue.global().async {
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 1024)
            while data.count < payload.count {
                let count = recv(peer, &bytes, bytes.count, 0)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            XCTAssertEqual(data, payload)
            received.fulfill()
        }
        await fulfillment(of: [written, received], timeout: 4)
    }

    func testCancellationCompletesBlockedReadAndWrite() async throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        var limit: Int32 = 1024
        XCTAssertEqual(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &limit, socklen_t(MemoryLayout<Int32>.size)), 0)
        let queue = DispatchQueue(label: "socket-cancel-test")
        let connection = try RemoteSocketConnection(fd: pair[0], queue: queue)
        defer { close(pair[1]) }
        let read = expectation(description: "Pending read cancelled")
        let write = expectation(description: "Backpressured write cancelled")
        queue.sync {
            connection.read { _, _, error in XCTAssertNotNil(error); read.fulfill() }
        }
        connection.write(Data(repeating: 65, count: 128 * 1024), final: false) { error in
            XCTAssertNotNil(error); write.fulfill()
        }
        queue.sync { connection.cancel(); connection.cancel() }
        await fulfillment(of: [read, write], timeout: 2)
    }

    func testSocketListenerRejectsWildcardLANAndNoncanonicalAddresses() {
        for address in ["0.0.0.0", "192.168.1.10", "::", "100.075.118.39"] {
            XCTAssertThrowsError(try RemoteSocketListener(address: address, port: 47321, queue: .global(), accept: { _ in }))
        }
    }
}
