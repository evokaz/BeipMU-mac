import Foundation

enum LegacyConfigurationTestSupport {
    static let sourceFixture = """
    // Keep this comment byte-for-byte
    Version=265
    Connections
    {
      Shortcuts
      {
        LambdaMOO
        {
          Host="lambda.moo.mud.org:8888"
          Encoding=CP1252
          Triggers { { Disabled=false } }
        }
      }
    }
    Unknown.Future.Value="preserve me"
    """

    static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }
}

struct PersistenceSeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

