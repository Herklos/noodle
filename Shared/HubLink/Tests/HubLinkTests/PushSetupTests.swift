import CloudKit
import Foundation
import HubLink
import XCTest

/// Apple's side of telling devices away from the Hub about unread replies, checked against what the
/// code writes and what the public releases' entitlements claim: the CloudKit container's schema and
/// the Developer ID profiles. Those checks need a CloudKit management token and the profiles, so they
/// are skipped without them; scripts/verify-push-setup.sh runs them with PUSH_SETUP_REQUIRED=1, where
/// anything missing fails instead. They live with the Hub link, which holds the record the Hub writes, so
/// that script builds nothing else.
final class PushSetupTests: XCTestCase {
    private static let apps = [
        (name: "Noodle", bundle: "com.pdparchitect.noodle", entitlements: "Support/Noodle-Release.entitlements"),
        (name: "Hub", bundle: "com.pdparchitect.noodle.hub", entitlements: "Hub/Support/Hub-Release.entitlements"),
    ]

    /// Both public releases reach the container the code writes to, in one environment.
    func testReleasesReachTheContainerTheCodeWritesTo() throws {
        for app in Self.apps {
            let claimed = try Self.plist(app.entitlements)
            XCTAssertEqual(claimed["com.apple.developer.icloud-container-identifiers"] as? [String], [LinkPush.container], app.name)
            XCTAssertEqual(claimed["com.apple.developer.icloud-services"] as? [String], ["CloudKit"], app.name)
        }
        XCTAssertEqual(Set(try Self.apps.map { try Self.environment(of: $0.entitlements) }).count, 1)
    }

    func testExportedSchemasAreRead() throws {
        let schema = """
        DEFINE SCHEMA

            RECORD TYPE Users (
                "___recordID" REFERENCE QUERYABLE,
                roles         LIST<INT64>,
                GRANT WRITE TO "_creator"
            );

            RECORD TYPE "Ping" (
                "___recordID" REFERENCE QUERYABLE,
                conversation  STRING,
                topic         STRING QUERYABLE,
                unread        INT64,
                GRANT WRITE TO "_creator",
                GRANT CREATE TO "_icloud",
                GRANT READ TO "_world"
            );
        """
        let ping = try XCTUnwrap(Self.recordType("Ping", in: schema))
        XCTAssertEqual(ping.fields["topic"], ["STRING", "QUERYABLE"])
        XCTAssertEqual(ping.fields["unread"], ["INT64"])
        XCTAssertEqual(ping.grants, ["GRANT WRITE TO _creator", "GRANT CREATE TO _icloud", "GRANT READ TO _world"])
        XCTAssertEqual(Self.recordType("Users", in: schema)?.fields["roles"], ["LIST<INT64>"])
        XCTAssertNil(Self.recordType("Pong", in: schema))
    }

    /// The container holds, in the environment the releases use, the record type the Hub writes: each
    /// field of the type the code gives it, the topic devices subscribe by queryable, and the Hub free
    /// to create and replace its records while any device may read them.
    func testTheContainerHoldsWhatTheHubWrites() throws {
        let environment = try Self.environment(of: Self.apps[0].entitlements).lowercased()
        let team = try Self.team()
        let schema = try exportSchema(team: team, environment: environment)
        let sample = LinkPush.record(topic: "topic", conversation: UUID(), unread: 1)
        let type = try XCTUnwrap(Self.recordType(sample.recordType, in: schema),
                                 "The \(environment) schema has no \(sample.recordType) record type. Deploy the schema to \(environment).")
        for key in sample.allKeys() {
            XCTAssertEqual(type.fields[key]?.first, Self.schemaType(of: sample[key]), "\(sample.recordType).\(key) in \(environment)")
        }
        XCTAssertTrue(type.fields[LinkPush.topicField]?.contains("QUERYABLE") == true,
                      "\(sample.recordType).\(LinkPush.topicField) must be queryable in \(environment): devices subscribe by it.")
        for grant in ["GRANT CREATE TO _icloud", "GRANT WRITE TO _creator", "GRANT READ TO _world"] {
            XCTAssertTrue(type.grants.contains(grant), "\(sample.recordType) in \(environment) lacks \(grant)")
        }
    }

    /// Each public release's Developer ID profile is for its app, still valid, and allows every iCloud
    /// entitlement the release claims; without it the app would not launch.
    func testTheProfilesAllowWhatTheReleasesClaim() throws {
        // A release checks only its own app's profile.
        let only = ProcessInfo.processInfo.environment["PUSH_SETUP_APPS"]?.split(separator: " ").map(String.init)
        for app in Self.apps where only?.contains(app.name) ?? true {
            let variable = "\(app.name.uppercased())_PROVISIONING_PROFILE_PATH"
            guard let path = ProcessInfo.processInfo.environment[variable] else {
                try unavailable("\(variable) is not set.")
            }
            let profile = try Self.decodeProfile(at: path)
            let granted = try XCTUnwrap(profile["Entitlements"] as? [String: Any], app.name)
            let team = try XCTUnwrap((profile["TeamIdentifier"] as? [String])?.first, app.name)
            XCTAssertEqual(granted["com.apple.application-identifier"] as? String, "\(team).\(app.bundle)", app.name)
            XCTAssertGreaterThan(try XCTUnwrap(profile["ExpirationDate"] as? Date), Date(), "\(app.name)'s profile has expired.")
            for (key, value) in try Self.plist(app.entitlements) where key.hasPrefix("com.apple.developer.") {
                XCTAssertTrue(Self.allows(granted[key], value), "\(app.name)'s profile does not allow \(key).")
            }
        }
    }

    private var required: Bool { ProcessInfo.processInfo.environment["PUSH_SETUP_REQUIRED"] == "1" }

    /// Stops the check: skipped in ordinary test runs, failed with the reason when the setup is required.
    private func unavailable(_ reason: String) throws -> Never {
        if required { throw Unavailable(description: reason) }
        throw XCTSkip(reason)
    }

    private struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    /// Uses CLOUDKIT_MANAGEMENT_TOKEN, or a token saved with `xcrun cktool save-token --type management`.
    private func exportSchema(team: String, environment: String) throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("push-schema-\(UUID()).ckdb")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["cktool", "export-schema", "--team-id", team, "--container-id", LinkPush.container,
                             "--environment", environment, "--output-file", output.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let schema = try? String(contentsOf: output, encoding: .utf8)
        if schema != nil { try? FileManager.default.removeItem(at: output) }
        if message.contains("No management token") {
            try unavailable("No CloudKit management token: set CLOUDKIT_MANAGEMENT_TOKEN or run xcrun cktool save-token --type management.")
        }
        guard process.terminationStatus == 0, let schema else {
            throw Unavailable(description: "cktool could not export the \(environment) schema: \(message)")
        }
        return schema
    }

    /// One record type of an exported schema: each field's type and attributes, and its grants.
    static func recordType(_ name: String, in schema: String) -> (fields: [String: [String]], grants: [String])? {
        guard let start = schema.range(of: "RECORD TYPE \(name) (") ?? schema.range(of: "RECORD TYPE \"\(name)\" ("),
              let end = schema.range(of: ");", range: start.upperBound..<schema.endIndex) else { return nil }
        var fields: [String: [String]] = [:], grants: [String] = []
        for line in schema[start.upperBound..<end.lowerBound].split(separator: ",") {
            let words = line.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard let first = words.first else { continue }
            if first == "GRANT" { grants.append(words.joined(separator: " ")) } else { fields[first] = Array(words.dropFirst()) }
        }
        return (fields, grants)
    }

    /// The schema's name for the type of a value the code writes.
    private static func schemaType(of value: (any CKRecordValueProtocol)?) -> String? {
        switch value {
        case is String: "STRING"
        case let number as NSNumber: CFNumberIsFloatType(number) ? "DOUBLE" : "INT64"
        case is Date: "TIMESTAMP"
        case is Data: "BYTES"
        case is CKRecord.Reference: "REFERENCE"
        case is CKAsset: "ASSET"
        default: nil
        }
    }

    /// Whether a profile's entitlement allows what a release claims: the same, or a wildcard, or for a list, all of it.
    private static func allows(_ granted: Any?, _ claimed: Any) -> Bool {
        switch (granted, claimed) {
        case (let granted as String, let claimed as String): granted == claimed || granted == "*"
        case (let granted as [String], let claimed as [String]): Set(claimed).isSubset(of: granted) || granted.contains("*")
        case (let granted as String, is [String]): granted == "*"
        default: false
        }
    }

    private static func environment(of entitlements: String) throws -> String {
        try XCTUnwrap(try plist(entitlements)["com.apple.developer.icloud-container-environment"] as? String, entitlements)
    }

    /// The team every app is signed for, as its project names it.
    private static func team() throws -> String {
        let project = try String(contentsOf: repository.appendingPathComponent("Project.swift"), encoding: .utf8)
        let match = try XCTUnwrap(project.firstMatch(of: try Regex(#""DEVELOPMENT_TEAM": "([A-Z0-9]{10})""#)))
        return try XCTUnwrap(match.output[1].substring.map(String.init))
    }

    private static func decodeProfile(at path: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
    }

    // Shared/HubLink/Tests/HubLinkTests/ is five levels down.
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repository.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
    }
}
