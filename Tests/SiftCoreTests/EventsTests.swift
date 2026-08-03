import XCTest

@testable import SiftCore

final class EventsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Encoding

    func testRoundTrips() throws {
        let event = SiftEvent(
            ts: "2026-08-03T17:50:00Z", kind: .optimize, path: "/a/b.png",
            before: 100, after: 40)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(SiftEvent.self, from: data), event)
    }

    func testMakeStampsTimestamp() {
        let event = SiftEvent.make(kind: .move, path: "/a", to: "/b")
        XCTAssertFalse(event.ts.isEmpty)
        XCTAssertEqual(event.kind, .move)
        XCTAssertEqual(event.to, "/b")
        XCTAssertNil(event.before)
    }

    // MARK: - Appending

    func testAppendWritesOneLinePerEvent() throws {
        let path = dir.appendingPathComponent("nested/events.jsonl").path
        let log = EventLog(path: path)
        log.append(SiftEvent.make(kind: .move, path: "/a", to: "/b"))
        log.append(SiftEvent.make(kind: .optimize, path: "/c.png", before: 10, after: 5))
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.split(separator: "\n").count, 2)
        for line in contents.split(separator: "\n") {
            XCTAssertNoThrow(try JSONDecoder().decode(SiftEvent.self, from: Data(line.utf8)))
        }
    }

    func testAppendCreatesMissingDirectory() {
        let path = dir.appendingPathComponent("a/b/c/events.jsonl").path
        EventLog(path: path).append(SiftEvent.make(kind: .move, path: "/x"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testAppendFailureIsSilent() {
        // An unwritable location must never break a run.
        EventLog(path: "/no/such/dir/events.jsonl").append(
            SiftEvent.make(kind: .move, path: "/x"))
    }

    // MARK: - Reading

    func testReadEventsSkipsMalformedLines() throws {
        let path = dir.appendingPathComponent("events.jsonl").path
        let good = #"{"ts":"2026-08-03T00:00:00Z","kind":"move","path":"/a"}"#
        try "\(good)\nnot json\n\n\(good)\n".write(
            toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(readEvents(at: path).count, 2)
    }

    func testReadEventsMissingFileIsEmpty() {
        XCTAssertTrue(readEvents(at: dir.appendingPathComponent("nope.jsonl").path).isEmpty)
    }

    func testReadAllMergesArchivesNewestFirst() throws {
        let archive = dir.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        func line(_ ts: String, _ path: String) -> String {
            #"{"ts":"\#(ts)","kind":"move","path":"\#(path)"}"#
        }
        try line("2026-08-03T00:00:00Z", "/new").write(
            toFile: dir.appendingPathComponent("events.jsonl").path,
            atomically: true, encoding: .utf8)
        try line("2026-07-01T00:00:00Z", "/old").write(
            toFile: archive.appendingPathComponent("events.jsonl").path,
            atomically: true, encoding: .utf8)
        try line("2026-07-15T00:00:00Z", "/mid").write(
            toFile: archive.appendingPathComponent("events 2.jsonl").path,
            atomically: true, encoding: .utf8)
        let all = readAllEvents(logDirectory: dir.path)
        XCTAssertEqual(all.map(\.path), ["/new", "/mid", "/old"])
    }

    func testReadAllToleratesMissingEverything() {
        XCTAssertTrue(readAllEvents(logDirectory: dir.path).isEmpty)
    }

    // MARK: - Path derivation

    func testEventLogPathSitsBesideTheTextLog() {
        let settings = Settings(
            interval: "1h", log: "~/Library/Logs/Sift/sift.log", dryRun: false,
            categories: [:], tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
        let config = Config(settings: settings, folders: [])
        XCTAssertEqual(
            eventLogPath(for: config),
            NSHomeDirectory() + "/Library/Logs/Sift/events.jsonl")
    }
}
