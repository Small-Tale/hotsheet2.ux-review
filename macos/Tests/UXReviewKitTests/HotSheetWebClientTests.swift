import Foundation
import Network
import Testing
@testable import UXReviewKit

/// HS2-ZEF6XD: finding the running Hot Sheet 2 web client from its `client.json`, and the ticket
/// deep link a filed review opens.
struct HotSheetWebClientTests {
    private func home(_ json: String?) throws -> URL {
        let home = try TestSupport.makeTempDirectory()
        if let json { try Data(json.utf8).write(to: home.appendingPathComponent(HotSheetWebClient.discoveryFilename)) }
        return home
    }

    @Test func homeIsHotSheetHomeOrDotHotsheet2() {
        #expect(HotSheetWebClient.home(environment: ["HOTSHEET_HOME": "/tmp/hs"]).path == "/tmp/hs")
        #expect(HotSheetWebClient.home(environment: ["HOTSHEET_HOME": "  "]).lastPathComponent == ".hotsheet2")
        #expect(HotSheetWebClient.home(environment: [:]).path.hasSuffix("/.hotsheet2"))
    }

    @Test(arguments: [
        (#"{"pid": 42, "url": "http://127.0.0.1:4175", "started_at": "x", "id": "y"}"#, "http://127.0.0.1:4175"),
        (#"{"pid": 42, "url": "http://[::1]:4175"}"#, "http://[::1]:4175"),
        (#"{"pid": 42, "url": "http://localhost:5173/"}"#, "http://localhost:5173/"),
    ])
    func readsALoopbackRecord(json: String, url: String) throws {
        let home = try home(json)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HotSheetWebClient.read(home: home) == HotSheetWebClient(url: try #require(URL(string: url)), pid: 42))
    }

    @Test(arguments: [
        nil,
        "not json",
        #"{"url": "http://127.0.0.1:4175"}"#,
        #"{"pid": 0, "url": "http://127.0.0.1:4175"}"#,
        #"{"pid": 42, "url": "http://example.com:4175"}"#,
        #"{"pid": 42, "url": "http://192.168.1.4:4175"}"#,
        #"{"pid": 42, "url": "file:///etc/passwd"}"#,
        #"{"pid": 42, "url": ""}"#,
    ])
    func ignoresMissingBrokenOrRemoteRecords(json: String?) throws {
        let home = try home(json)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HotSheetWebClient.read(home: home) == nil)
    }

    @Test func discoverRequiresALiveProcessThatAnswers() throws {
        let home = try home(#"{"pid": 42, "url": "http://127.0.0.1:4175"}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HOTSHEET_HOME": home.path]
        #expect(HotSheetWebClient.discover(environment: env, isAlive: { _ in true }, responds: { _ in true })?.pid == 42)
        #expect(HotSheetWebClient.discover(environment: env, isAlive: { _ in false }, responds: { _ in true }) == nil)
        #expect(HotSheetWebClient.discover(environment: env, isAlive: { _ in true }, responds: { _ in false }) == nil)
        // A record that disappears (the host shut down) is no client.
        try FileManager.default.removeItem(at: home.appendingPathComponent(HotSheetWebClient.discoveryFilename))
        #expect(HotSheetWebClient.discover(environment: env, isAlive: { _ in true }, responds: { _ in true }) == nil)
    }

    @Test func processIsAliveForThisProcessOnly() {
        #expect(HotSheetWebClient.processIsAlive(getpid()))
        #expect(!HotSheetWebClient.processIsAlive(Int32.max))
    }

    @Test func deepLinkEncodesTheStoreAndTicket() throws {
        let client = HotSheetWebClient(url: try #require(URL(string: "http://127.0.0.1:4175")), pid: 1)
        #expect(
            client.ticketURL(project: nil, store: "/Users/me/Code/acme-mail.hs2", ticket: "HS2-ZEF6XD").absoluteString
                == "http://127.0.0.1:4175/?store=/Users/me/Code/acme-mail.hs2&ticket=HS2-ZEF6XD"
        )
        let odd = client.ticketURL(project: nil, store: "/Users/me/My Code/a+b&c=d.hs2", ticket: "HS-1")
        #expect(odd.absoluteString == "http://127.0.0.1:4175/?store=/Users/me/My%20Code/a%2Bb%26c%3Dd.hs2&ticket=HS-1")
        let components = try #require(URLComponents(url: odd, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "store" }?.value == "/Users/me/My Code/a+b&c=d.hs2")
        let withPath = HotSheetWebClient(url: try #require(URL(string: "http://localhost:5173/app/")), pid: 1)
        #expect(withPath.ticketURL(project: nil, store: "s", ticket: "t").absoluteString == "http://localhost:5173/app/?store=s&ticket=t")
    }

    /// HS2-G3BA3P: the link names the project the reviewer chose, not its store.
    @Test func deepLinkNamesTheProjectWhenItIsKnown() throws {
        let client = HotSheetWebClient(url: try #require(URL(string: "http://127.0.0.1:4176")), pid: 1)
        let store = "/Users/me/Documents/hotsheet2.hs2"
        #expect(
            client.ticketURL(project: "/Users/me/Documents/hotsheet2", store: store, ticket: "HS2-EH01R7").absoluteString
                == "http://127.0.0.1:4176/?store=/Users/me/Documents/hotsheet2&ticket=HS2-EH01R7"
        )
        // A trailing slash or `..` is standardized away; a blank project falls back to the store.
        #expect(
            client.ticketURL(project: "/Users/me/Documents/x/../hotsheet2/", store: store, ticket: "T").absoluteString
                == "http://127.0.0.1:4176/?store=/Users/me/Documents/hotsheet2&ticket=T"
        )
        #expect(
            client.ticketURL(project: "  ", store: store, ticket: "T").absoluteString
                == "http://127.0.0.1:4176/?store=/Users/me/Documents/hotsheet2.hs2&ticket=T"
        )
        // Spaces and reserved characters in the project path are encoded like a store path.
        let odd = client.ticketURL(project: "/Users/me/My Code/a+b", store: store, ticket: "T")
        let components = try #require(URLComponents(url: odd, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "store" }?.value == "/Users/me/My Code/a+b")
    }

    @Test(.timeLimit(.minutes(1))) func answersOnlyWhenSomethingListens() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0) }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var iterator = ready.makeAsyncIterator()
        let next = await iterator.next()
        let port = try #require(next)
        let live = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        let answered = await Task.detached { HotSheetWebClient.answers(live) }.value
        #expect(answered, "any HTTP status counts")
        listener.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let answeredAfterClose = await Task.detached { HotSheetWebClient.answers(live, timeout: 0.5) }.value
        #expect(!answeredAfterClose)
    }
}
