@testable import BeipPersistence
import Foundation
import XCTest

final class PersistenceResilienceTests: XCTestCase {
    private let validConfig = """
    Version=331
    Connections
    {
      Shortcuts
      {
      }
    }
    """

    func testConfigurationRecoverySkipsCorruptTruncatedAndNewerCandidatesWithoutTouchingPrimary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("Config.txt")
        let validBackup = directory.appendingPathComponent("Config.backup-2026-07-24.txt")
        let newerBackup = directory.appendingPathComponent("Config.backup-2026-07-25.txt")
        try Data(validConfig.utf8).write(to: validBackup)
        try Data("Version=999\n".utf8).write(to: newerBackup)
        try setModificationDate(.now.addingTimeInterval(-60), for: validBackup)
        try setModificationDate(.now, for: newerBackup)

        let damagedPrimaries = [
            Data([0xff, 0xfe, 0xfd]),
            Data("Version=331\nConnections\n{\n".utf8),
            Data("Version=999\nConnections {}\n".utf8),
        ]
        for damaged in damagedPrimaries {
            try damaged.write(to: primary)
            let recovery = try await LegacyConfigurationStore(url: primary).loadRecoveringFromBackup()
            XCTAssertEqual(recovery.document.value(at: ["Version"]), "331")
            XCTAssertEqual(recovery.recoveredFrom?.lastPathComponent, validBackup.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: primary), damaged)
        }
    }

    func testMalformedAtlasXMLArchiveAndUnsafeArchivePathsAreRejected() throws {
        XCTAssertThrowsError(try AtlasReader.read(from: Data("<atlas><map>".utf8)))

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let malformedArchive = directory.appendingPathComponent("Malformed.atlas")
        try Data([0x50, 0x4b, 0x03, 0x04, 0xff]).write(to: malformedArchive)
        XCTAssertThrowsError(try AtlasReader.readArchive(from: malformedArchive))

        var unsafeData = try AtlasWriter.archiveData(for: .init(
            atlas: Atlas(version: 2, maps: [.init(name: "Main")]),
            resources: ["safe/file": Data("asset".utf8)]
        ))
        replaceAll(Data("safe/file".utf8), with: Data("../escape".utf8), in: &unsafeData)
        let unsafeArchive = directory.appendingPathComponent("Unsafe.atlas")
        try unsafeData.write(to: unsafeArchive)
        XCTAssertThrowsError(try AtlasReader.readArchive(from: unsafeArchive)) { error in
            guard case AtlasError.unsafeResourcePath("../escape") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAllPersistenceStoresPreservePrimaryAtBothAtomicFailureBoundaries() async throws {
        for stage in AtomicFileWriter.Stage.allCases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let writer = AtomicFileWriter(failingAt: stage)

            let configURL = directory.appendingPathComponent("Config.txt")
            let originalConfig = Data(validConfig.utf8)
            try originalConfig.write(to: configURL)
            let configStore = LegacyConfigurationStore(url: configURL, writer: writer)
            var editedConfig = try await configStore.load()
            try editedConfig.upsertValue("local", at: ["ResilienceEdit"])
            await XCTAssertThrowsErrorAsync(try await configStore.save(editedConfig)) { error in
                XCTAssertEqual(error as? AtomicFileWriter.WriterError, .injectedFailure(stage))
            }
            XCTAssertEqual(try Data(contentsOf: configURL), originalConfig)

            let sidecarURL = directory.appendingPathComponent("Config.mac.json")
            let originalSidecar = MacConfigurationSidecar(keyEquivalents: ["Connect": "@["])
            try MacSidecarStore.save(originalSidecar, to: sidecarURL)
            XCTAssertThrowsError(try MacSidecarStore.save(
                .init(pathMappings: ["C:\\Logs": "~/Logs"]),
                to: sidecarURL,
                writer: writer
            ))
            XCTAssertEqual(try MacSidecarStore.load(from: sidecarURL), originalSidecar)

            let atlasURL = directory.appendingPathComponent("Map.atlas")
            let originalAtlas = AtlasArchive(atlas: .init(
                version: 2,
                maps: [.init(name: "Original")]
            ))
            try AtlasWriter.write(originalAtlas, to: atlasURL)
            XCTAssertThrowsError(try AtlasWriter.write(
                .init(atlas: .init(version: 2, maps: [.init(name: "Edited")])),
                to: atlasURL,
                writer: writer
            ))
            XCTAssertEqual(try AtlasReader.readArchive(from: atlasURL), originalAtlas)

            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains(where: { $0.hasSuffix(".tmp") }))
        }
    }

    func testExternalConfigurationEditPreservesPrimaryAndWritesLocalConflictCopy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Config.txt")
        try Data(validConfig.utf8).write(to: url)

        let store = LegacyConfigurationStore(url: url)
        var local = try await store.load()
        try local.upsertValue("local-value", at: ["LocalEdit"])
        let external = validConfig + "\nExternalEdit=\"external-value\"\n"
        try Data(external.utf8).write(to: url)

        do {
            try await store.save(local)
            XCTFail("save should report the external modification")
        } catch let LegacyConfigurationError.externalChange(conflictURL) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), external)
            XCTAssertEqual(
                try LegacyConfigurationDocument(
                    source: String(contentsOf: conflictURL, encoding: .utf8)
                ).value(at: ["LocalEdit"]),
                "local-value"
            )
            XCTAssertTrue(
                LegacyConfigurationError.externalChange(conflictURL)
                    .localizedDescription.contains(conflictURL.path)
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testExternalEditAtAtomicReplaceBoundaryIsAlsoReportedAsConflict() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Config.txt")
        try Data(validConfig.utf8).write(to: url)
        let external = Data((validConfig + "\nBoundaryEdit=true\n").utf8)
        let writer = AtomicFileWriter(beforeReplace: { destination in
            try external.write(to: destination)
        })
        let store = LegacyConfigurationStore(url: url, writer: writer)
        var local = try await store.load()
        try local.upsertValue("local-value", at: ["LocalEdit"])

        do {
            try await store.save(local)
            XCTFail("save should report the boundary modification")
        } catch let LegacyConfigurationError.externalChange(conflictURL) {
            XCTAssertEqual(try Data(contentsOf: url), external)
            XCTAssertEqual(
                try LegacyConfigurationDocument(
                    source: String(contentsOf: conflictURL, encoding: .utf8)
                ).value(at: ["LocalEdit"]),
                "local-value"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBackupCreationFailureLeavesLastValidConfigurationReadable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Config.txt")
        let original = Data(validConfig.utf8)
        try original.write(to: url)

        let store = LegacyConfigurationStore(
            url: url,
            backupWriter: AtomicFileWriter(failingAt: .replace)
        )
        var edited = try await store.load()
        try edited.upsertValue("edited", at: ["AttemptedEdit"])
        await XCTAssertThrowsErrorAsync(try await store.save(edited))

        XCTAssertEqual(try Data(contentsOf: url), original)
        let reopened = try await LegacyConfigurationStore(url: url).load()
        XCTAssertEqual(reopened.value(at: ["Version"]), "331")
        XCTAssertNil(reopened.value(at: ["AttemptedEdit"]))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Resilience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func replaceAll(_ target: Data, with replacement: Data, in data: inout Data) {
        precondition(target.count == replacement.count)
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let range = data.range(of: target, in: searchStart..<data.endIndex) {
            data.replaceSubrange(range, with: replacement)
            searchStart = range.lowerBound + replacement.count
        }
    }

}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
