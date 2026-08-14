@testable import BeipPersistence
import BeipCore
import Foundation
import XCTest

final class SessionRecoveryStoreTests: XCTestCase {
    func testBoundedStorageAndPerSessionIsolation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Recovery.dat")
        let store = try SessionRecoveryStore(url: url, capacity: 8_192, perSessionCapacity: 1_800)
        let first = try store.beginSession(serverName: "First")
        let second = try store.beginSession(serverName: "Second")

        for index in 0..<30 {
            try store.append(
                .renderedLine(.init(text: "first-\(index)-" + String(repeating: "x", count: 120))),
                to: first
            )
            try store.append(
                .sentInput("second-\(index)-" + String(repeating: "y", count: 120)),
                to: second
            )
        }

        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, store.capacity)
        XCTAssertTrue(store.session(id: first)?.records.allSatisfy {
            if case .renderedLine = $0.event { return true }
            return false
        } == true)
        XCTAssertTrue(store.session(id: second)?.records.allSatisfy {
            if case .sentInput = $0.event { return true }
            return false
        } == true)
    }

    func testDurableWritesAndCompactionDoNotDuplicateRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Recovery.dat")
        let store = try SessionRecoveryStore(url: url, capacity: 16_384, perSessionCapacity: 8_000)
        let id = try store.beginSession(serverName: "World", characterName: "Hero")
        for value in ["one", "two", "three"] {
            try store.append(.sentInput(value), to: id)
        }
        try store.compact()
        try store.flush()

        let reopened = try SessionRecoveryStore(url: url, capacity: 16_384, perSessionCapacity: 8_000)
        XCTAssertEqual(reopened.session(id: id)?.records.count, 3)
        XCTAssertEqual(reopened.session(id: id)?.serverName, "World")
        XCTAssertEqual(reopened.session(id: id)?.characterName, "Hero")
    }

    func testTruncatedFinalFrameKeepsTheValidPrefix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Recovery.dat")
        do {
            let store = try SessionRecoveryStore(url: url, capacity: 16_384)
            let id = try store.beginSession(serverName: "World")
            try store.append(.sentInput("valid"), to: id)
            try store.append(.sentInput("torn tail"), to: id)
            try store.flush()
        }

        let data = try Data(contentsOf: url)
        try data.dropLast(3).write(to: url)
        let reopened = try SessionRecoveryStore(url: url, capacity: 16_384)
        let values = reopened.session(id: reopened.sessions[0].id)?.records.compactMap { record -> String? in
            if case let .sentInput(value) = record.event { return value }
            return nil
        }
        XCTAssertEqual(values, ["valid"])
        XCTAssertLessThan(try Data(contentsOf: url).count, data.count)
    }

    func testDiscardRemovesOnlyTheSelectedSession() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionRecoveryStore(url: directory.appendingPathComponent("Recovery.dat"))
        let first = try store.beginSession(serverName: "First")
        let second = try store.beginSession(serverName: "Second")
        try store.append(.gmcp(.init(package: "Room.Info", payload: "{}")), to: first)
        try store.append(.renderedLine(.init(text: "second")), to: second)

        try store.discard(first)

        XCTAssertNil(store.session(id: first))
        XCTAssertEqual(store.session(id: second)?.records.count, 1)
    }

    func testResetEmptiesAndDurablyCompactsTheOpenJournal() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Recovery.dat")
        let store = try SessionRecoveryStore(url: url)
        let id = try store.beginSession(serverName: "World")
        try store.append(.sentInput("secret"), to: id)

        try store.reset()

        XCTAssertEqual(store.sessionCount, 0)
        XCTAssertTrue(store.sessions.isEmpty)
        let reopened = try SessionRecoveryStore(url: url)
        XCTAssertTrue(reopened.sessions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("BeipMU Recovery 1\n".utf8))
    }

    func testSavedCharacterUsesOnePersistentBufferAndSupportsRenameAndRemoval() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionRecoveryStore(url: directory.appendingPathComponent("Recovery.dat"))
        let serverID = UUID()
        let characterID = UUID()
        let first = try store.beginSession(
            serverID: serverID,
            characterID: characterID,
            serverName: "World",
            characterName: "Hero"
        )
        try store.append(.sentInput("look"), to: first)
        let resumed = try store.beginSession(
            serverID: serverID,
            characterID: characterID,
            serverName: "Renamed World",
            characterName: "Renamed Hero"
        )

        XCTAssertEqual(first, resumed)
        XCTAssertEqual(store.sessionCount, 1)
        XCTAssertEqual(store.session(id: first)?.characterName, "Renamed Hero")
        XCTAssertEqual(store.session(id: first)?.records.count, 1)

        try store.removeBuffer(characterID: characterID)
        XCTAssertEqual(store.sessionCount, 0)
    }

    func testDisableClearsAllBuffersAndStatisticsReportPhysicalSize() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Recovery.dat")
        let store = try SessionRecoveryStore(url: url)
        _ = try store.beginSession(
            serverID: UUID(), characterID: UUID(), serverName: "World", characterName: "Hero"
        )

        XCTAssertEqual(store.statistics.bufferCount, 1)
        XCTAssertEqual(store.statistics.fileSize, try Data(contentsOf: url).count)

        try store.setEnabled(false)
        XCTAssertEqual(store.statistics.bufferCount, 0)
        XCTAssertEqual(store.statistics.fileSize, Data("BeipMU Recovery 1\n".utf8).count)
    }

    func testEnqueuedBurstFlushesInOrderAndReopensCompletely() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Recovery.dat")
        let store = try SessionRecoveryStore(
            url: url,
            capacity: 4 * 1_024 * 1_024,
            perSessionCapacity: 4 * 1_024 * 1_024
        )
        let id = try store.beginSession(serverName: "World", characterName: "Hero")

        let start = ContinuousClock.now
        for index in 0..<5_000 {
            store.enqueue(.sentInput("event-\(index)"), to: id)
        }
        let enqueueDuration = start.duration(to: .now)
        XCTAssertLessThan(enqueueDuration, .seconds(1))

        try store.flush()
        let reopened = try SessionRecoveryStore(
            url: url,
            capacity: 4 * 1_024 * 1_024,
            perSessionCapacity: 4 * 1_024 * 1_024
        )
        let values = reopened.session(id: id)?.records.compactMap { record -> String? in
            if case let .sentInput(value) = record.event { return value }
            return nil
        }
        XCTAssertEqual(values, (0..<5_000).map { "event-\($0)" })
    }

    func testResetDisableResizeAndRemoveAreBarriersForEnqueuedEvents() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Recovery.dat")
        let store = try SessionRecoveryStore(url: url, capacity: 64 * 1_024)
        let resetID = try store.beginSession(serverName: "Reset")
        for index in 0..<500 { store.enqueue(.sentInput("reset-\(index)"), to: resetID) }
        try store.reset()
        XCTAssertTrue(store.sessions.isEmpty)

        let removeID = try store.beginSession(serverName: "Remove")
        for index in 0..<500 { store.enqueue(.sentInput("remove-\(index)"), to: removeID) }
        try store.setPerCharacterCapacity(32 * 1_024)
        try store.remove(sessionID: removeID)
        XCTAssertNil(store.session(id: removeID))

        let disableID = try store.beginSession(serverName: "Disable")
        for index in 0..<500 { store.enqueue(.sentInput("disable-\(index)"), to: disableID) }
        try store.setEnabled(false)
        try store.flush()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("BeipMU Recovery 1\n".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.SessionRecoveryStoreTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
