// Reads a project's schema.json (Epic A2: A2.1's portable type vocabulary,
// A2.3's versioned artifact) from Swift — see this file's own top-level
// doc comment on Shovelbase.swift for what this SDK actually is.
//
// SCOPE NOTE (A2.6, #51): this SDK is a device-side client — there is no
// build step, no local filesystem project, and (for Tier 0 SQLite apps) no
// on-device database file for Swift code to author a schema into or apply a
// migration against; both already happen entirely through the JS SDK + CLI
// (`shovelbase schema build/push`, `shovelbase migration generate`, `db
// push`), exactly the way Postgres/Tier 1 migrations already work today.
// So "parity" here is read-only: a typed Swift decoding of the same
// schema.json shape A2.1 emits, for client code that wants to introspect a
// project's schema (e.g. to validate a response shape) without hand-rolling
// the JSON. Schema *authoring* and *migration application* from Swift are
// out of scope for the reasons above — see the PR/issue for the full
// reasoning; this is a deliberate scope call, not an oversight.

import Foundation

/// A project's schema.json, decoded — mirrors `sdk/src/schema.js`'s IR exactly
/// (same field names, same shape) so a schema.json emitted by the JS SDK
/// round-trips through this decoder unchanged.
public struct ShovelbaseSchema: Codable, Equatable, Sendable {
    public var tables: [ShovelbaseSchemaTable]

    public init(tables: [ShovelbaseSchemaTable]) {
        self.tables = tables
    }
}

public struct ShovelbaseSchemaTable: Codable, Equatable, Sendable {
    public var name: String
    public var columns: [ShovelbaseSchemaColumn]
    public var indexes: [ShovelbaseSchemaIndex]
    public var constraints: [ShovelbaseSchemaConstraint]

    public init(
        name: String,
        columns: [ShovelbaseSchemaColumn],
        indexes: [ShovelbaseSchemaIndex] = [],
        constraints: [ShovelbaseSchemaConstraint] = []
    ) {
        self.name = name
        self.columns = columns
        self.indexes = indexes
        self.constraints = constraints
    }
}

/// The portable type vocabulary from `sdk/src/schema.js`'s `TYPES` — kept as
/// a plain `String` `RawRepresentable` rather than an exhaustive enum, so a
/// schema.json written by a newer JS SDK with one more type than this SDK
/// knows about still decodes instead of throwing.
public struct ShovelbaseSchemaType: RawRepresentable, Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let text: Self = "text"
    public static let int: Self = "int"
    public static let bigint: Self = "bigint"
    public static let real: Self = "real"
    public static let boolean: Self = "boolean"
    public static let timestamp: Self = "timestamp"
    public static let uuid: Self = "uuid"
    public static let json: Self = "json"
    public static let blob: Self = "blob"
}

/// A column's `default`, which in schema.json is a JSON literal (string,
/// number, boolean) or `null` — never an object/array (`schema.js`'s own
/// `formatLiteral` only accepts those three primitive kinds).
public enum ShovelbaseSchemaDefault: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "column default must be a string, number, boolean, or null"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct ShovelbaseSchemaColumn: Codable, Equatable, Sendable {
    public var name: String
    public var type: ShovelbaseSchemaType
    public var nullable: Bool
    public var `default`: ShovelbaseSchemaDefault

    public init(name: String, type: ShovelbaseSchemaType, nullable: Bool = true, default: ShovelbaseSchemaDefault = .null) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.default = `default`
    }
}

public struct ShovelbaseSchemaIndex: Codable, Equatable, Sendable {
    public var name: String
    public var columns: [String]
    public var unique: Bool

    public init(name: String, columns: [String], unique: Bool = false) {
        self.name = name
        self.columns = columns
        self.unique = unique
    }
}

/// `onDelete` action for a foreign-key constraint — matches `schema.js`'s
/// `ON_DELETE_ACTIONS` (`cascade`, `setNull`, `restrict`, `noAction`).
public struct ShovelbaseOnDeleteAction: RawRepresentable, Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let cascade: Self = "cascade"
    public static let setNull: Self = "setNull"
    public static let restrict: Self = "restrict"
    public static let noAction: Self = "noAction"
}

public struct ShovelbaseSchemaForeignKeyReference: Codable, Equatable, Sendable {
    public var table: String
    public var columns: [String]

    public init(table: String, columns: [String]) {
        self.table = table
        self.columns = columns
    }
}

/// A table-level constraint — `primaryKey` and `unique` only carry `columns`;
/// `foreignKey` additionally carries `references` and `onDelete`. Mirrors
/// `schema.js`'s three `kind`s as one flat, optional-field struct (rather
/// than a Swift enum with associated values) because that is the literal
/// shape schema.json itself uses — decoding a real schema.json produced by
/// the JS SDK should never require translating its shape first.
public struct ShovelbaseSchemaConstraint: Codable, Equatable, Sendable {
    public var kind: String
    public var columns: [String]
    public var references: ShovelbaseSchemaForeignKeyReference?
    public var onDelete: ShovelbaseOnDeleteAction?

    public init(
        kind: String,
        columns: [String],
        references: ShovelbaseSchemaForeignKeyReference? = nil,
        onDelete: ShovelbaseOnDeleteAction? = nil
    ) {
        self.kind = kind
        self.columns = columns
        self.references = references
        self.onDelete = onDelete
    }
}

extension ShovelbaseSchema {
    /// Decodes a schema.json document (as emitted by `shovelbase schema
    /// build`/`push`, A2.3) from raw bytes.
    public static func decode(_ data: Data) throws -> ShovelbaseSchema {
        try JSONDecoder().decode(ShovelbaseSchema.self, from: data)
    }
}
