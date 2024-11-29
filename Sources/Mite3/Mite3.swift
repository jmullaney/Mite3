//  Mite3.swift

import Foundation
#if !MITE3_CUSTOM_SQLITE3
import SQLite3
#endif

public typealias Mite3Result = Result<Int32, Mite3Error>
public typealias Mite3QueryResult<Row> = Result<[Row], Mite3Error>
public typealias Mite3GetResult<Row> = Result<Row, Mite3Error>
public typealias Mite3GetOptionalResult<Row> = Result<Row?, Mite3Error>

/// An error type.
///
/// - .sqlite3Error represents an sqliet3 error code. The error includes extended information about the error, when available.
/// - .paramBindingError is a non-sqlite3 parameter binding error, such as when an error is thrown while encoding.
/// - .rowReadingError is a non-sqlite3 row reading error, such as when an error us thrown while decoding.
public enum Mite3Error: Error {
    case sqlite3Error(_ code: Int32, extended: ExtendedSqlite3ErrorInfo)
    case paramBindingError(_ error: Error?, _ message: String? = nil)
    case rowReadingError(_ error: Error?, _ message: String? = nil)
    
    public struct ExtendedSqlite3ErrorInfo: Sendable {
        let primaryCode: Int32
        let errstr: String?
        let errmsg: String?
        let sql: String?
        let errorOffset: Int32
        let codeSymbol: String?
        let codeComment: String?
        let primarySymbol: String?
        let primaryComment: String?
    }
    
    init(code: Int32) {
        let errstr: String? = if let cstr = sqlite3_errstr(code) { String(cString: cstr) } else { nil }
        self = .sqlite3Error(code, extended: .init(code: code, errstr: errstr))
    }
    
    init(pDb: OpaquePointer, code: Int32) {
        let errstr: String? = if let cstr = sqlite3_errstr(code) { String(cString: cstr) } else { nil }
        let errmsg: String? = if let cstr = sqlite3_errmsg(pDb) { String(cString: cstr) } else { nil }
        self = .sqlite3Error(code, extended: .init(code: code, errstr: errstr, errmsg: errmsg))
    }
    
    init(pDb: OpaquePointer, code: Int32, sql: String, errorOffset: Int32) {
        let errstr: String? = if let cstr = sqlite3_errstr(code) { String(cString: cstr) } else { nil }
        let errmsg: String? = if let cstr = sqlite3_errmsg(pDb) { String(cString: cstr) } else { nil }
        self = .sqlite3Error(code, extended: .init(code: code, errstr: errstr, errmsg: errmsg, sql: sql, errorOffset: errorOffset))
    }
}

/// Utilities to make it easier and more convenient to use sqlite3 from Swift and
/// reduce related boilerplate code.
///
/// Note: this is specifically intended to <u>not</u> wrap sqlite3. That makes this useful for, e.g., creating an application-level data access wrapper
/// around sqlite where an intermediate wrapper would ultimately get in the way more than help.
///
/// | | |
/// |-|-|
/// | Result Code Utilities | convert the result of calling an sqlite3 API function to a thrown error when the result is an error, or to a success/failure `Result<S,F>`. |
/// | `exec()` / `query()` / `get()` / `getOptional()` | Execute SQL statments on a database connection. Accepts `Encodable` values for parameters, and any `Decodable` for results. |
/// | `getInt()` / `getOptionalInt()` / `getString()` / `getOptionalString()` | Convenient variants of get() and getOptional() that return a specific type of value. |
/// | Binding and reading to/from statements | Use the same `Codable`-based parameter binding and row reading that the `exec`, `query*` and `get*` functions provide, but directly on sqlite3 statements prepared outside of Mite3.|
/// | `Mite3.Value` utility type| A variant type capable of directly representing sqlite3 fundamental data types. |
/// | `Mite3.CustomRepresentation` | Customizing how Mite3 binds/reads values to/from statements. |
///
/// ### Usage Examples ###
///
///
/// ```swift
///     var pDb: OpaquePointer! = nil
///     try Mite3.call { sqlite3_open(":memory:", &pDb) }
///     defer { sqlite3_close(pDb) }
///
///     try Mite3.exec(pDb: pDb, sql: "CREATE TABLE user (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
///     try Mite3.exec(pDb: pDb,
///         sql: "INSERT INTO user(name) VALUES (?), (?), (?)",
///         params: "John Smith", "Annie Oakley", "Jerry West"
///     )
///
///     let jUsers = try Mite3.query(pDb: pDb,
///         sql: "SELECT id, name FROM user WHERE name like ? ORDER BY name",
///         params: "J%",
///         type: User.self
///     )
///     print(jUsers) // output: [{"id":3,"name":"Jerry West"}, {"id":1,"name":"John Smith"}]
///
///     let aRowOfValues = try Mite3.get(pDb: pDb,
///         sql: "SELECT datetime('2024-10-03 10:11:12') someDate, 1+2+3 someNum, 'abc' someStr",
///         type: [Mite3.Value].self
///     )
///     print(aRowOfValues[0]) // output: 2024-10-03 10:11:12
///     print(aRowOfValues[1]) // output: 6
///     print(aRowOfValues[2]) // output: abc
///
///     struct User: Codable, CustomStringConvertible {
///         let id: Int
///         let name: String
///         let notes: String?
///         var description: String { String(data: try! JSONEncoder().encode(self), encoding: .utf8)! }
///     }
/// ```
///
/// ### Result Code Utilities ###
///
/// These are functions to convert the result of calling an sqlite3 API function to a thrown error when
/// the result is an error, or to a success/failure `Result<S,F>`.
///
/// The errors generated contain extended information about the error. This is pulled from sqlite3_errstr() and, when the database
/// connection is provided, sqlite3_errmsg(). The symbolic name of the code is also provided, as well as code comments from
/// the sqlite3 source code (it's possible for these to get out-of-date, though the symbols tend to be stable).
///
/// ### exec/query/get ###
///
/// These functions execute SQL statements on a database connection.
///
/// Parameters can be specified as Encodable values and the results are returned as a Decodable type.
///
/// - Use the `exec` variants without callback when you don't need results returned.
/// - Use the `exec` variants with callback when you want results returned via callback.
/// - Use the `query` variants when you want all the result rows returned.
/// - Use the `get` variants when you want one row returned. (If the SQL could return multiple rows, the first one is returned.) An error occurs if
///   at least one row isn't returned.
/// - Use the `getOptional` variants when you want at most one row returned. (If the SQL could return multiple rows, the first one is returned.
///
/// ### Binding Parameters and Reading Rows Directly to/from Statemenets ###
///
/// `Mite3.bindParameters()` lets you bind parameters from Decodable values in the same way as `exec`, `query*`, and `get*`, but you
/// can do it directly on an sqlite3 statement pointer. This lets you use the Mite3 binding on a statement you prepare outside of Mite3.
///
/// `Mite3.readRow()` lets you read the current row to an Encodable type in the same way as `exec`, `query*` and `get*`, but you
/// can do it directly from an sqlite3 statement pointer. You would use this when you're preparing your statement and calling
/// `sqlite3_step()` outside of Mite3, but still want to use its row reading mechanism.
///
/// ### Utility Types ###
///
/// `Mite3.Value`
///
/// This is a variant value corresponding to the five sqlite3 fundamental data types.
/// See https://www.sqlite.org/c3ref/c_blob.html
///
/// - .INTEGER corresponds to SQLITE_INTEGER. The value is Int64
/// - .FLOAT corresponds to SQLITE_FLOAT. The value is Double
/// - .TEXT corresponds to SQLITE_3_TEXT. The value is String
/// - .BLOB correspionds to SQLITE_BLOB. The value is Data
/// - .NULL corresponds to SQLITE_NULL. There is no stored value, but you can consider nil the implicit value.
///
/// This can be useful for receiving arbitrary values in a form the same as or losslessly converted from the form sqlite3 uses.
/// E.g., you can use [Mite3.Value].self as the result type for any query, and receive whatever values sqlite3 provides.
///
/// ### Parameter Binding and Row Reading ###
///
/// Functions accept SQL parameters through a variadic `params: Encodable...` parameter.
/// This means you can specify zero, one, or more SQL parameters, as needed by the SQL being
/// executed.
///
/// - Certain common types have a standard binding (see below). These are accepted as-is, and
///   are bound by index to SQL parameters.
/// - When an array value is specified directly, its elements are bound by index to SQL parameters.
///   Extra values are ignored.
/// - When an object/struct is specified, its properties are bound by name, case-insensitive, to SQL
///   paramerers, using the object's `Encodable` coding keys as named. Extra properties -- those
///   that don't correspond to a SQL parameter -- are ignored.
/// - Types can implement  `Mite3.CustomRepresentation` to customize how its values
///   are bound as a sqlite parameter (see below).
///
/// Note: since `params` is variadic, multiple arrays and objects may be specified. In that case, values
/// bound from later arrays and objects overwrite values bound from earlier ones. (Use this capability
/// carefully, since it's confusing and usually not necessary.)
///
/// Note 2: values nested in an array or object that don't have a standard or custom representation
/// are serialized using a JSONEncoder.
///
/// Results are converted to Swift types that implement `Decodable`.
///
/// - When the result row type is a simple value, it's value is read from the first column value
/// - When the result row type is an array of values, the row is returned as an array of column values.
/// - When the result row type is a complex object, each property's value is read from the result columns by
///   property name (case-insensitive), using the Decodable coding key.
///
/// ### Standard Binding/Reading ###
///
///     | Swift Type | sqlite3 data type               |
///     | Int8       | INTEGER (64-bit integer)        |
///     | UInt8      | INTEGER (64-bit integer)        |
///     | Int16      | INTEGER (64-bit integer)        |
///     | UInt16     | INTEGER (64-bit integer)        |
///     | Int32      | INTEGER (64-bit integer)        |
///     | UInt32     | INTEGER (64-bit integer)        |
///     | Int64      | INTEGER (64-bit integer)        |
///     | UInt64     | TEXT                            |
///     | Int128     | TEXT                            |
///     | UInt128    | TEXT                            |
///     | Int        | INTEGER (64-bit integer)        |
///     | UInt       | TEXT                            |
///     | Bool       | 0 or 1 INTEGER (64-bit integer) |
///     | Float      | FLOAT (64-bit floating point)   |
///     | Double     | FLOAT (64-bit floating point)   |
///     | String     | TEXT                            |
///     | Data       | BLOB (bytes)                    |
///     | Date       | as ISO 8601 date/time as TEXT   |
///
/// Nested `Codable` values are encoded/decoded as JSON as use sqlite3's TEXT data type.
///
/// ### Customizing Parameter Binding and Row Reading ###
///
/// You can extend a type to implement `Mite3.CustomRepresentation` to customize how values of
/// the type are bound as parameters or read as result row column values.
///
/// `func bind(binder: ParameterBinder) -> Int32` determins how a value is bound as a parameter.
/// The ParameterBinder instance passed in provides utilities for binding various kinds of primitive values in a typical way.
/// You can use these utility functions or directly use the sqlite3 binding APIs on statement pointer however needed.
///
/// `init?(from reader: ColumnReader)` determines how a value is read.
/// The ColumnReader instance passed in provides utilities for reads various kinds of primitive values in a typical way.
/// You can use these utility functions or directly use the sqlite3 column APIs on the statement pointer however needed.
///
/// As an alternative to  `Mite3.CustomRepresentation`, you can customize a type's Ecodable and Decodable
/// implenentation (unless it already has a standard form, as mentioned above). Note that CustomRepresentation has
/// precedence over the Codable implementation.
///
/// ### Mite3.Connection ###
///
/// Provides an OO-style interface as an alternative to the functions that take a database pointer as the first parameter.
public struct Mite3 {
    
    ///
    /// ### Result Code Utilities ###
    ///

    /// Accepts an sqlite3 result code. Throws if it's an error code not listed in `except`.
    /// The error includes content from sqlite3_errstr() and some other extended information.
    public static func throwError(_ code: Int32, except: Set<Int32> = []) throws(Mite3Error) { _ = try mite3ThrowError(code, except: except) }

    /// Accepts an sqlite3 database connection and result code. Throws if it's an error code not listed in `except`.
    /// The error includes content from sqlite3_errstr(), sqlite3_errmsg() and some other extended information.
    public static func throwError(pDb: OpaquePointer?, _ code: Int32, except: Set<Int32> = []) throws(Mite3Error) { _ = try mite3ThrowError(pDb: pDb, code, except: except) }

    /// Executes a block returning an sqlite3 result code. Throws if the block returns an error code not in `except`.
    public static func call(block: () -> Int32, except: Set<Int32> = []) throws (Mite3Error) { _ = try mite3ThrowError(block(), except: except) }

    /// Accepts an sqlite3 result code. Throws if it's an error code not listed in `except`. Otherwise returns the result code.
    /// The error includes content from sqlite3_errstr() and some other extended information.
    public static func throwErrorRc(_ code: Int32, except: Set<Int32> = []) throws(Mite3Error) -> Int32 { try mite3ThrowError(code, except: except) }

    /// Accepts an sqlite3 result code. Throws if it's an error code not listed in `except`. Otherwise returns the result code.
    /// The error includes content from sqlite3_errstr(), sqlite3_errmsg() and some other extended information.
    public static func throwErrorRc(pDb: OpaquePointer?, _ code: Int32, except: Set<Int32> = []) throws(Mite3Error) -> Int32 { try mite3ThrowError(pDb: pDb, code, except: except) }

    /// Executes a block returning an sqlite3 result code. Throws if the block returns an error code not in `except`. Otherwise returns the result code.
    public static func callRc(block: () -> Int32, except: Set<Int32> = []) throws (Mite3Error) -> Int32 { try mite3ThrowError(block(), except: except) }

    /// Executes a block returning an sqlite3 result code. Returns a result indicating success or failure.
    /// Error codes not in `except` result in a failure. Other result codes result in success.
    /// The error includes content from sqlite3_errstr() and some other extended information.
    public static func result(block: () -> Int32, except: Set<Int32> = []) -> Mite3Result { mite3Result(code: block(), except: except) }

    /// Executes a block returning an sqlite3 result code. Returns a result indicating success or failure.
    /// Error codes not in `except` result in a failure. Other result codes result in success.
    /// The error includes content from sqlite3_errstr(), sqlite3_errmsg() and some other extended information.
    public static func result(pDb: OpaquePointer?, code: Int32, except: Set<Int32> = []) -> Mite3Result { mite3Result(pDb: pDb, code: code, except: except) }
    
    /// Executes SQL statements. Accepts Encodable parameters, and a callback for receiving result rows.
    ///
    /// - Parameters:
    ///     - pDb: The sqlite3 database connection handle typically returned from `sqlite3_open()`
    ///     - sql: The SQL to execute. This may contain multiple statements, though all resutls need to be compatible with the row type the callback uses.
    ///     - params: Parameters to the SQL.
    ///     - callback: A closure/function called for each result row. If the callback returns false, no further execution of the SQL will occur.
    ///
    /// Example:
    ///
    /// ```swift
    /// struct User { let id: Int, let name: String }
    ///
    /// try Mite3.exec(pDb: pDb,
    ///     sql: "SELECT id, name FROM users WHERE name like ? AND lastlogin > date(?)",
    ///     params: "J%", "2024-01-01",
    ///     callback: { (user: User) -> Bool in
    ///         print("found \(user.name)!")
    ///         return false
    ///     }
    /// )
    /// ```
    public static func exec<Row: Decodable>(pDb: OpaquePointer, sql: String, params: Encodable..., callback: (Row) -> Bool) throws (Mite3Error) {
        _ = try mite3Exec(pDb: pDb, sqlCString: sql, params: params, callback: callback)
    }
    
    /// exec() variant with no callback
    ///
    /// - Parameters:
    ///     - pDb: The sqlite3 database connection handle typically returned from `sqlite3_open()`
    ///     - sql: The SQL to execute. This may contain multiple statements, though all resutls need to be compatible with the row type the callback uses.
    ///     - params: Parameters to the SQL.
    ///
    /// Example:
    ///
    /// ```swift
    /// try Mite3.exec(pDb: pDb,
    ///     sql: "INSERT INTO users(name) VALUE (?)",
    ///     params: "Mr. Smith"
    /// )
    /// ```
    public static func exec(pDb: OpaquePointer, sql: String, params: Encodable...) throws (Mite3Error) {
        _ = try mite3Exec(pDb: pDb, sqlCString: sql, params: params, callback: emptyRowReturnTrueCallback)
    }

    /// Executes SQL and returns all the result rows.
    ///
    /// Parameter pDb: The sqlite3 database connection handle typically returned from `sqlite3_open()`
    /// Parameter sql: The SQL to execute. This may contain multiple statements, though all resutls need to be compatible with the result row type.
    /// Parameter params: Parameters to the SQL.
    /// Parameter type: The type of rows returned
    /// Returns: array of result rows.
    ///
    /// Example:
    ///
    /// ```swift
    /// struct User { let id: Int, let name: String }
    ///
    /// let rows = try Mite3.query(pDb: pDb,
    ///     sql: "SELECT * FROM users WHERE name like ?",
    ///     params: ["M%"],
    ///     type: User.self
    /// )
    /// ```
    public static func query<Row: Decodable>(pDb: OpaquePointer, sql: String, params: Encodable..., type: Row.Type) throws (Mite3Error) -> [Row] {
        try mite3Query(pDb: pDb, sql: sql, params: params, type: type)
    }

    /// Executes SQL and returns the first result row
    public static func get<Row: Decodable>(pDb: OpaquePointer, sql: String, params: Encodable..., type: Row.Type) throws (Mite3Error) -> Row {
        try mite3Get(pDb: pDb, sql: sql, params: params, type: type)
    }

    /// Executes SQL and returns the first result row as an integer
    public static func getInt(pDb: OpaquePointer, sql: String, params: Encodable...) throws (Mite3Error) -> Int {
        try mite3Get(pDb: pDb, sql: sql, params: params, type: Int.self)
    }

    /// Executes SQL and returns the first result row as a string
    public static func getString(pDb: OpaquePointer, sql: String, params: Encodable...) throws (Mite3Error) -> String {
        try mite3Get(pDb: pDb, sql: sql, params: params, type: String.self)
    }

    /// Executes SQL and returns the first result row, if any.
    public static func getOptional<Row: Decodable>(pDb: OpaquePointer, sql: String, params: Encodable..., type: Row.Type) throws (Mite3Error) -> Row? {
        try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: type)
    }

    /// Executes SQL and returns the first result row as an integer, if any.
    public static func getOptionalInt(pDb: OpaquePointer, sql: String, params: Encodable...) throws (Mite3Error) -> Int? {
        try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: Int.self)
    }

    /// Executes SQL and returns the first result row as a string, if any.
    public static func getOptionalString(pDb: OpaquePointer, sql: String, params: Encodable...) throws (Mite3Error) -> String? {
        try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: String.self)
    }

    /// Binds `Encodable` parameters to a prepared statement.
    ///
    /// Use this when you want to use Mite3 parameter bindings on statements prepared outside of Mite3.
    public static func bindParameters(pStmt: OpaquePointer, params: Encodable...) throws (Mite3Error) {
        _ = try mite3BindParameters(pStmt: pStmt, params: params)
    }

    /// Reads a `Decodable` row from a statement.
    ///
    /// Use this when you want to use Mite3 row loading on statements prepared and executed outside of Mite3.
    /// This should be after sqlite3_step(pStmt) returns SQLITE_ROW.
    public static func readRow<Row: Decodable>(pStmt: OpaquePointer, type: Row.Type) throws (Mite3Error) -> Row {
        try mite3ReadRow(pStmt: pStmt, type: type)
    }
    
    public static let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
    public static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// This is a variant value corresponding to the five sqlite3 fundamental data types.
    /// See https://www.sqlite.org/c3ref/c_blob.html
    ///
    /// - .INTEGER corresponds to SQLITE_INTEGER. The value is Int64
    /// - .FLOAT corresponds to SQLITE_FLOAT. The value is Double
    /// - .TEXT corresponds to SQLITE_3_TEXT. The value is String
    /// - .BLOB correspionds to SQLITE_BLOB. The value is Data
    /// - .NULL corresponds to SQLITE_NULL. There is no stored value, but you can consider nil the implicit value.
    public enum Value: Sendable, Equatable, Codable {
        case INTEGER(Int64)
        case FLOAT(Double)
        case TEXT(String)
        case BLOB(Data)
        case NULL
    }
    
    /// Implement this on types where you want to directly customize the sqlite3 parameter binding and row reading.
    /// See the struct documentation for more discussion.
    public protocol CustomRepresentation {
        func bind(binder: ParameterBinder) -> Int32
        init?(from reader: ColumnReader)
    }

    /// Provides a statement, parameter index, and some utilities for custom parameter binding.
    /// See the struct documentation for more discussion.
    public struct ParameterBinder {
        let pStmt: OpaquePointer
        let index: Int32

        func bindNil() -> Int32 { sqlite3_bind_null(pStmt, index)}
        func bind(_ value: Int8) -> Int32 { sqlite3_bind_int(pStmt, index, Int32(value)) }
        func bind(_ value: UInt8) -> Int32 { sqlite3_bind_int(pStmt, index, Int32(value)) }
        func bind(_ value: Int16) -> Int32 { sqlite3_bind_int(pStmt, index, Int32(value)) }
        func bind(_ value: UInt16) -> Int32 { sqlite3_bind_int(pStmt, index, Int32(value)) }
        func bind(_ value: Int32) -> Int32 { sqlite3_bind_int(pStmt, index, value) }
        func bind(_ value: UInt32) -> Int32 { sqlite3_bind_int64(pStmt, index, Int64(value)) }
        func bind(_ value: Int64) -> Int32 { sqlite3_bind_int64(pStmt, index, value) }
        func bind(_ value: UInt64) -> Int32 { sqlite3_bind_text(pStmt, index, value.description, -1, SQLITE_TRANSIENT) }
        @available(macOS 15.0, *)
        @available(macCatalyst 18.0, *)
        @available(iOS 18.0, *)
        @available(watchOS 11.0, *)
        @available(visionOS 2.0, *)
        @available(tvOS 18.0, *)
        func bind(_ value: Int128) -> Int32 { sqlite3_bind_text(pStmt, index, value.description, -1, SQLITE_TRANSIENT) }
        @available(macOS 15.0, *)
        @available(macCatalyst 18.0, *)
        @available(iOS 18.0, *)
        @available(watchOS 11.0, *)
        @available(visionOS 2.0, *)
        @available(tvOS 18.0, *)
        func bind(_ value: UInt128) -> Int32 { sqlite3_bind_text(pStmt, index, value.description, -1, SQLITE_TRANSIENT) }
        func bind(_ value: Int) -> Int32 { sqlite3_bind_int64(pStmt, index, Int64(value)) }
        func bind(_ value: UInt) -> Int32 { sqlite3_bind_text(pStmt, index, value.description, -1, SQLITE_TRANSIENT) }
        func bind(_ value: Bool) -> Int32 { sqlite3_bind_int(pStmt, index, value ? 1 : 0) }
        func bind(_ value: Float) -> Int32 { sqlite3_bind_double(pStmt, index, Double(value)) }
        func bind(_ value: Double) -> Int32 { sqlite3_bind_double(pStmt, index, value) }
        func bind(_ value: String) -> Int32 { sqlite3_bind_text(pStmt, index, value, -1, SQLITE_TRANSIENT) }
        func bind(_ value: Data) -> Int32 {
            value.withUnsafeBytes { buf in
                sqlite3_bind_blob64(pStmt, index, buf.baseAddress, UInt64(buf.count), SQLITE_TRANSIENT)
            }
        }
        func bindIso8601(_ value: Date) -> Int32 { sqlite3_bind_text(pStmt, index, mite3Iso8601LocalMsFormatter.string(from: value), -1, SQLITE_TRANSIENT) }
        func bindUnixEpoch(_ value: Date) -> Int32 { sqlite3_bind_double(pStmt, index, value.timeIntervalSince1970) }
        func bindJulianDay(_ value: Date) -> Int32 { sqlite3_bind_double(pStmt, index, 2440587.5 + value.timeIntervalSince1970 / 86400) }

        func bind<T: Encodable>(_ value: T) throws (Mite3Error) -> Int32 {
            do {
                let resultCode = switch value {
                case let value as Mite3.CustomRepresentation:
                    value.bind(binder: self)
                case let value as StandardRepresentation:
                    value.standardBind(binder: self)
                default:
                    (try JSONEncoder().encode(value)).standardBind(binder: self)
                }
                return try mite3ThrowBindError(pStmt: pStmt, resultCode)
            } catch let error as Mite3Error {
                throw error
            } catch {
                throw Mite3Error.paramBindingError(error, "failed binding \(value)")
            }
        }
        
        init(pStmt: OpaquePointer, index: Int32) {
            self.pStmt = pStmt
            self.index = index
        }
        
        init (pStmt: OpaquePointer, key: CodingKey) {
            self.pStmt = pStmt
            if let intValue = key.intValue {
                self.index = Int32(intValue) + 1
            } else {
                var intIndex = sqlite3_bind_parameter_index(pStmt, ":\(key.stringValue)")
                if intIndex == 0 {
                    intIndex = sqlite3_bind_parameter_index(pStmt, "@\(key.stringValue)")
                    if intIndex == 0 {
                        intIndex = sqlite3_bind_parameter_index(pStmt, "$\(key.stringValue)")
                        if intIndex == 0 {
                            intIndex = sqlite3_bind_parameter_index(pStmt, key.stringValue)
                        }
                    }
                }
                self.index = intIndex
            }
        }
    }
    
    /// Provides a statement, column index, and some utilities for custom column  reading.
    /// See the struct documentation for more discussion.
    public struct ColumnReader {
        let pStmt: OpaquePointer
        let column: Int32

        func readNil() -> Bool { sqlite3_column_type(pStmt, column) == SQLITE_NULL }
        func readInt8() -> Int8? { Int8(exactly: sqlite3_column_int(pStmt, column)) }
        func readUInt8() -> UInt8? { UInt8(exactly: sqlite3_column_int(pStmt, column)) }
        func readInt16() -> Int16? { Int16(exactly: sqlite3_column_int(pStmt, column)) }
        func readUInt16() -> UInt16? { UInt16(exactly: sqlite3_column_int(pStmt, column)) }
        func readInt32() -> Int32 { sqlite3_column_int(pStmt, column) }
        func readUInt32() -> UInt32? { UInt32(exactly: sqlite3_column_int64(pStmt, column))}
        func readInt64() -> Int64 { sqlite3_column_int64(pStmt, column) }
        func readUInt64() -> UInt64? { if let text = sqlite3_column_text(pStmt, column) { UInt64(String(cString: text)) } else { nil } }
        @available(macOS 15.0, *)
        @available(macCatalyst 18.0, *)
        @available(iOS 18.0, *)
        @available(watchOS 11.0, *)
        @available(visionOS 2.0, *)
        @available(tvOS 18.0, *)
        func readInt128() -> Int128? { if let text = sqlite3_column_text(pStmt, column) { Int128(String(cString: text)) } else { nil } }
        @available(macOS 15.0, *)
        @available(macCatalyst 18.0, *)
        @available(iOS 18.0, *)
        @available(watchOS 11.0, *)
        @available(visionOS 2.0, *)
        @available(tvOS 18.0, *)
        func readUInt128() -> UInt128? { if let text = sqlite3_column_text(pStmt, column) { UInt128(String(cString: text)) } else { nil } }
        func readInt() -> Int? { Int(exactly: sqlite3_column_int64(pStmt, column)) }
        func readUInt() -> UInt? { if let text = sqlite3_column_text(pStmt, column) { UInt(String(cString: text)) } else { nil } }
        func readBool() -> Bool { sqlite3_column_int(pStmt, column) != 0 }
        func readFloat() -> Float { Float(sqlite3_column_double(pStmt, column)) }
        func readDouble() -> Double { sqlite3_column_double(pStmt, column) }
        func readString() -> String? { if let text = sqlite3_column_text(pStmt, column) { String(cString: text) } else { nil } }
        func readData() -> Data? {
            if let pBytes = sqlite3_column_blob(pStmt, column), let byteCount = Int(exactly: sqlite3_column_bytes(pStmt, column)) {
                Data(bytes: pBytes, count: byteCount)
            } else {
                nil
            }
        }
        func readIso8601() -> Date? { if let string = readString() { mite3ParseIso8601DateTime(string: string) } else { nil } }
        func readUnixEpoch() -> Date? { Date(timeIntervalSince1970: readDouble()) }
        func readJulianDay() -> Date? { Date(timeIntervalSince1970: (readDouble() - 2440587.5) * 86400) }
    }

    /// Provides an OO-style interface as an alternative to the functions that take a database pointer as the first parameter.
    public class Connection {
        public let pDb: OpaquePointer
        public let closeAutomatically: Bool

        public init(pDb: OpaquePointer, closeAutomatically: Bool = true) {
            self.pDb = pDb
            self.closeAutomatically = closeAutomatically
        }

        public init(filename: String) throws (Mite3Error) {
            var pDb: OpaquePointer? = nil
            _ = try Mite3.call { sqlite3_open(filename, &pDb) }
            guard let pDb = pDb else { throw Mite3Error(code: SQLITE_ERROR) }
            self.pDb = pDb
            self.closeAutomatically = true
        }
        
        public init(filename: String, flags: Int32, vfs: String? = nil) throws (Mite3Error) {
            var pDb: OpaquePointer? = nil
            _ = try Mite3.call { sqlite3_open_v2(filename, &pDb, flags, vfs) }
            guard let pDb = pDb else { throw Mite3Error(code: SQLITE_ERROR) }
            self.pDb = pDb
            self.closeAutomatically = true
        }

        deinit {
            if closeAutomatically {
                sqlite3_close(pDb)
            }
        }

        public func result(block: () -> Int32, except: Set<Int32> = []) -> Mite3Result {
            mite3Result(pDb: pDb, code: block(), except: except)
        }

        public func call(block: () -> Int32, except: Set<Int32> = []) throws (Mite3Error) {
            _ = try mite3Result(pDb: pDb, code: block(), except: except).get()
        }

        public func callRc(block: () -> Int32, except: Set<Int32> = []) throws (Mite3Error) -> Int32 {
            try mite3Result(pDb: pDb, code: block(), except: except).get()
        }

        public func exec<Row: Decodable>(sql: String, params: Encodable..., callback: (Row) -> Bool) throws (Mite3Error) {
            _ = try mite3Exec(pDb: pDb, sqlCString: sql, params: params, callback: callback)
        }
        
        public func exec(sql: String, params: Encodable...) throws (Mite3Error) {
            _ = try mite3Exec(pDb: pDb, sqlCString: sql, params: params, callback: emptyRowReturnTrueCallback)
        }

        public func query<Row: Decodable>(sql: String, params: Encodable..., type: Row.Type) throws (Mite3Error) -> [Row] {
            try mite3Query(pDb: pDb, sql: sql, params: params, type: type)
        }

        public func get<Row: Decodable>(sql: String, params: Encodable..., type: Row.Type) throws (Mite3Error) -> Row {
            try mite3Get(pDb: pDb, sql: sql, params: params, type: type)
        }

        public func getInt(sql: String, params: Encodable...) throws (Mite3Error) -> Int {
            try mite3Get(pDb: pDb, sql: sql, params: params, type: Int.self)
        }

        public func getString(sql: String, params: Encodable...) throws (Mite3Error) -> String {
            try mite3Get(pDb: pDb, sql: sql, params: params, type: String.self)
        }

        public func getOptional<Row: Decodable>(sql: String, params: Encodable..., type: Row.Type) throws (Mite3Error) -> Row? {
            try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: type)
        }

        public func getOptionalInt(sql: String, params: Encodable...) throws (Mite3Error) -> Int? {
            try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: Int.self)
        }

        public func getOptionalString(sql: String, params: Encodable...) throws (Mite3Error) -> String? {
            try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: String.self)
        }

        public func execResult<Row: Decodable>(sql: String, params: Encodable..., callback: (Row) -> Bool) -> Mite3Result {
            Mite3Result() { () throws (Mite3Error) in
                try mite3Exec(pDb: pDb, sqlCString: sql, params: params, callback: callback)
            }
        }
        
        public func execResult(sql: String, params: Encodable...) -> Mite3Result {
            Mite3Result() { () throws (Mite3Error) in
                try mite3Exec(pDb: pDb, sqlCString: sql, params: params, callback: emptyRowReturnTrueCallback)
            }
        }

        public func queryResult<Row: Decodable>(sql: String, params: Encodable..., type: Row.Type) -> Mite3QueryResult<Row> {
            Mite3QueryResult<Row>() { () throws (Mite3Error) in
                try mite3Query(pDb: pDb, sql: sql, params: params, type: type)
            }
        }

        public func getResult<Row: Decodable>(sql: String, params: Encodable..., type: Row.Type) -> Mite3GetResult<Row> {
            Mite3GetResult<Row>() { () throws (Mite3Error) in
                try mite3Get(pDb: pDb, sql: sql, params: params, type: type)
            }
        }

        public func getIntResult(sql: String, params: Encodable...) -> Mite3GetResult<Int> {
            Mite3GetResult<Int>() { () throws (Mite3Error) in
                try mite3Get(pDb: pDb, sql: sql, params: params, type: Int.self)
            }
        }

        public func getStringResult(sql: String, params: Encodable...) -> Mite3GetResult<String> {
            Mite3GetResult<String>() { () throws (Mite3Error) in
                try mite3Get(pDb: pDb, sql: sql, params: params, type: String.self)
            }
        }

        public func getOptionalResult<Row: Decodable>(sql: String, params: Encodable..., type: Row.Type) -> Mite3GetOptionalResult<Row> {
            Mite3GetOptionalResult<Row>() { () throws (Mite3Error) in
                try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: type)
            }
        }

        public func getOptionalIntResult(sql: String, params: Encodable...) -> Mite3GetOptionalResult<Int> {
            Mite3GetOptionalResult<Int>() { () throws (Mite3Error) in
                try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: Int.self)
            }
        }

        public func getOptionalStringResult(sql: String, params: Encodable...) -> Mite3GetOptionalResult<String> {
            Mite3GetOptionalResult<String>() { () throws (Mite3Error) in
                try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: String.self)
            }
        }
    }
}

fileprivate func mite3Query<Row: Decodable>(pDb: OpaquePointer, sql: String, params: [Encodable], type: Row.Type) throws (Mite3Error) -> [Row] {
    var rows: [Row] = []
    _ = try mite3Exec(pDb: pDb, sqlCString: sql, params: params, callback: { (row: Row) -> Bool in
        rows.append(row)
        return true
    })
    return rows
}

fileprivate func mite3Get<Row: Decodable>(pDb: OpaquePointer, sql: String, params: [Encodable], type: Row.Type) throws (Mite3Error) -> Row {
    if let row = try mite3GetOptional(pDb: pDb, sql: sql, params: params, type: type) {
        return row
    } else {
        throw Mite3Error.rowReadingError(nil, "no result row")
    }
}

fileprivate func mite3GetOptional<Row: Decodable>(pDb: OpaquePointer, sql: String, params: [Encodable], type: Row.Type) throws (Mite3Error) -> Row? {
    var resultRow: Row? = nil
    _ = try mite3Exec(pDb: pDb, sqlCString: sql, params: params, callback: { (row: Row) -> Bool in
        resultRow = row
        return false
    })
    return resultRow
}

fileprivate func mite3BindParameters(pStmt: OpaquePointer, params: [Encodable]) throws (Mite3Error) -> Int32 {
    var resultCode: Int32 = SQLITE_OK
    for p in params.enumerated() {
        let index = Int32(p.offset) + 1
        let param = p.element
        if let param = param as? Mite3.CustomRepresentation {
            let thisBindResult = param.bind(binder: Mite3.ParameterBinder(pStmt: pStmt, index: index))
            _ = try mite3ThrowBindError(pStmt: pStmt, thisBindResult)
            resultCode = resultCode == SQLITE_OK ? thisBindResult : resultCode
        } else if let param = param as? StandardRepresentation {
            let thisBindResult = param.standardBind(binder: Mite3.ParameterBinder(pStmt: pStmt, index: index))
            _ = try mite3ThrowBindError(pStmt: pStmt, thisBindResult)
            resultCode = resultCode == SQLITE_OK ? thisBindResult : resultCode
        } else {
            let paramsEncoder = Mite3ParamsEncoder(codingPath: [], userInfo: [:], pStmt: pStmt)
            do {
                try param.encode(to: paramsEncoder)
            } catch let error as Mite3Error {
                throw error
            } catch {
                throw Mite3Error.paramBindingError(error, "unexpected error binding parameters")
            }
        }
    }
    return resultCode
}

fileprivate func mite3ReadRow<Row: Decodable>(pStmt: OpaquePointer, type: Row.Type) throws (Mite3Error) -> Row {
    let rowDecoder: Decoder = Mite3RowDecoder(codingPath: [], userInfo: [:], rowReader: StatementRowReader(pStmt: pStmt))
    do {
        return try Row(from: rowDecoder)
    } catch let error as Mite3Error {
        throw error
    } catch {
        throw Mite3Error.rowReadingError(error, "unexpected error reading row")
    }
}

fileprivate func mite3Exec<Row: Decodable>(pDb: OpaquePointer, sqlCString: UnsafePointer<CChar>?, params: [Encodable], callback: (Row) -> Bool) throws (Mite3Error) -> Int32 {
    var pStmt: OpaquePointer? = nil
    var pTail: UnsafePointer<CChar>? = sqlCString
    
    statementLoop:
    while let pSql = pTail {
        
        try Mite3.call {
            sqlite3_prepare_v2(pDb, pSql, Int32(strlen(pTail!)), &pStmt, &pTail)
        }
        
        guard let pStmt = pStmt else {
            // happens when pTail is empty, which happens after the last statement is prepared
            return SQLITE_OK
        }
        defer { sqlite3_finalize(pStmt) }
        
        _ = try mite3BindParameters(pStmt: pStmt, params: params)
        
        stepLoop:
        while true {
            let code = sqlite3_step(pStmt)
            switch code {
            case SQLITE_DONE:
                continue statementLoop
            case SQLITE_ROW:
                let row = try Mite3.readRow(pStmt: pStmt, type: Row.self)
                if (!callback(row)) {
                    return SQLITE_ABORT // note: SQLITE_ABORT here does NOT throw an error. It's just a result code.
                }
                continue stepLoop
            default:
                throw Mite3Error(pDb: pDb, code: code)
            }
        } // stepLoop
    } // statementLoop
    
    return SQLITE_OK
}

fileprivate struct Mite3EmptyRow: Decodable {}
fileprivate func emptyRowReturnTrueCallback(row: Mite3EmptyRow) -> Bool { true }


fileprivate func mite3Result(code: Int32, except: Set<Int32>) -> Mite3Result {
    return if code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE || except.contains(code) {
        Mite3Result.success(code)
    } else {
        Mite3Result.failure(Mite3Error(code: code))
    }
}

fileprivate func mite3Result(pDb: OpaquePointer?, code: Int32, except: Set<Int32>) -> Mite3Result {
    return if code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE || except.contains(code) {
        Mite3Result.success(code)
    } else if let pDb = pDb {
        Mite3Result.failure(Mite3Error(pDb: pDb, code: code))
    } else {
        Mite3Result.failure(Mite3Error(code: code))
    }
}

fileprivate func mite3ThrowError(_ code: Int32, except: Set<Int32>) throws(Mite3Error) -> Int32 {
    guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE || except.contains(code) else {
        throw Mite3Error(code: code)
    }
    return code
}

fileprivate func mite3ThrowError(pDb: OpaquePointer?, _ code: Int32, except: Set<Int32>) throws(Mite3Error) -> Int32 {
    guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE || except.contains(code) else {
        if let pDb = pDb {
            throw Mite3Error(pDb: pDb, code: code)
        } else {
            throw Mite3Error(code: code)
        }
    }
    return code
}

fileprivate func mite3ThrowBindError(pStmt: OpaquePointer, _ code: Int32) throws(Mite3Error) -> Int32 {
    guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE || code == SQLITE_RANGE else {
        if let pDb = sqlite3_db_handle(pStmt) {
            throw Mite3Error(pDb: pDb, code: code)
        } else {
            throw Mite3Error(code: code)
        }
    }
    return code
}

extension Mite3.Value: CustomStringConvertible {
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .INTEGER(let value): try container.encode(value)
        case .FLOAT(let value): try container.encode(value)
        case .TEXT(let value): try container.encode(value)
        case .BLOB(let value): try container.encode([UInt8](value))
        case .NULL: try container.encodeNil()
        }
    }

    public init(from decoder: any Decoder) throws {

        if let rowDecoder = decoder as? Mite3RowDecoder, let value = Mite3.Value(fromStandard: Mite3.ColumnReader(pStmt: rowDecoder.rowReader.pStmt, column: 0)) {
            self = value
            return
        }

        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .NULL
            return
        }
        
        do {
            let value = try container.decode(Int64.self)
            self = .INTEGER(value)
            return
        } catch {}
        
        do {
            let value = try container.decode(Double.self)
            self = .FLOAT(value)
            return
        } catch {}
        
        do {
            let value = Data(try container.decode([UInt8].self))
            self = .BLOB(value)
            return
        } catch {}
        
        let value = try container.decode(String.self)
        self = .TEXT(value)
    }
    
    public var description: String {
        switch self {
        case .INTEGER(let value): String(describing: value)
        case .FLOAT(let value): String(describing: value)
        case .TEXT(let value): value
        case .BLOB(let value): String(describing: [UInt8](value))
        case .NULL: "NULL"
        }
    }
}

extension Mite3Error.ExtendedSqlite3ErrorInfo {
    fileprivate init(code: Int32, errstr: String? = nil, errmsg: String? = nil, sql: String? = nil, errorOffset: Int32 = -1) {
        self.primaryCode = code & 0xff
        self.errstr = errstr
        self.errmsg = errmsg
        self.sql = sql
        self.errorOffset = errorOffset
        (self.codeSymbol, self.codeComment) = if let info = mite3Sqlite3ResultCodeInfoMap[code] {
            (info.symbol, info.comment)
        } else {
            (nil, nil)
        }
        (self.primarySymbol, self.primaryComment) = if code == primaryCode {
            (self.codeSymbol, self.codeComment)
        } else if let primaryInfo = mite3Sqlite3ResultCodeInfoMap[code] {
            (primaryInfo.symbol, primaryInfo.comment)
        } else {
            (nil, nil)
        }
    }
}

extension Mite3Error: CustomStringConvertible {
    public var description: String {
        
        switch self {
        case .sqlite3Error(let code, let info):
            var parts = [
                code.description
            ]

            var subParts: [String] = []
            
            if let codeSymbol = info.codeSymbol {
                subParts.append(codeSymbol)
            }
            if info.primaryCode != code {
                subParts.append("primary: \(info.primaryCode)")
                if let primarySymbol = info.primarySymbol {
                    subParts.append(primarySymbol)
                }
            }
            
            if subParts.count != 0 {
                parts.append("(\(subParts.joined(separator: "; ")))")
            }
            
            if let generalErrorDesc = info.errstr ?? info.codeComment ?? info.primaryComment {
                parts.append(generalErrorDesc)
            }
            
            if let errmsg = info.errmsg {
                parts.append("- \(errmsg)")
            }
            if let sql = info.sql {
                parts.append("in \"\(sql)\"")
                if info.errorOffset != -1 {
                    parts.append("at offset \(info.errorOffset.description)")
                }
            }
            return "sqlite3 error: \(parts.joined(separator: " "))"
        case .paramBindingError(let error, let message):
            return if let error = error {
                if let message = message {
                    "\(message) - \(error)"
                } else {
                    "\(error)"
                }
            } else if let message = message {
                message
            } else {
                "swiftError"
            }
        case .rowReadingError(let error, let message):
            return if let error = error {
                if let message = message {
                    "\(message) - \(error)"
                } else {
                    "\(error)"
                }
            } else if let message = message {
                message
            } else {
                "swiftError"
            }
        }
    }
}

fileprivate struct StatementRowReader {

    let pStmt: OpaquePointer
    let columnNames: [String]
    let mapUpperColumnNameToIndex: [String:Int32]
    let columnCount: Int

    init(pStmt: OpaquePointer) {
        self.pStmt = pStmt
        let columnCount = sqlite3_column_count(pStmt)
        self.columnCount = Int(columnCount)
        self.columnNames = (0 ..< columnCount).map { columnIndex in
            String(cString: sqlite3_column_name(pStmt, columnIndex))
        }
        let kvps = columnNames.enumerated().map { index, name in (name.uppercased(), Int32(index)) }
        self.mapUpperColumnNameToIndex = Dictionary(kvps, uniquingKeysWith: { first, _ in first })
    }

    func readNil(column: Int32) throws(Mite3Error) -> Bool {
        sqlite3_column_type(pStmt, column) == SQLITE_NULL
    }

    func read<T: Decodable>(column: Int32, type: T.Type) throws(Mite3Error) -> T {
        let reader = Mite3.ColumnReader(pStmt: pStmt, column: column)
        if let type = type as? Mite3.CustomRepresentation.Type {
            if let value = type.init(from: reader) {
                return value as! T
            } else {
                throw Mite3Error.rowReadingError(nil, "Unable get value of column \"\(String(cString: sqlite3_column_name(pStmt, column)))\" (\(column)) as \(T.self)")
            }
        } else if let type = type as? StandardRepresentation.Type {
            if let value = type.init(fromStandard: reader) {
                return value as! T
            } else {
                throw Mite3Error.rowReadingError(nil, "Unable get value of column \"\(String(cString: sqlite3_column_name(pStmt, column)))\" (\(column)) as \(T.self)")
            }
        } else {
            let data = reader.readData() ?? Data()
            let jsonDecoder = JSONDecoder()
            do {
                return try jsonDecoder.decode(T.self, from: data)
            } catch let error as Mite3Error {
                throw error
            } catch {
                throw Mite3Error.rowReadingError(error, "Unable get value of column \"\(String(cString: sqlite3_column_name(pStmt, column)))\" (\(column)) as \(T.self)")
            }
        }
    }

    func readNil(key: CodingKey) throws(Mite3Error) -> Bool {
        try readNil(column: getColumn(from: key))
    }
    
    func contains(key: CodingKey) -> Bool {
        if let intValue = key.intValue {
            intValue >= 0 && intValue < columnCount
        } else {
            mapUpperColumnNameToIndex[key.stringValue.uppercased()] != nil
        }
    }

    func read<T: Decodable>(key: CodingKey, type: T.Type) throws(Mite3Error) -> T {
        try read(column: getColumn(from: key), type: type)
    }

    
    private func getColumn(from codingKey: CodingKey) throws(Mite3Error) -> Int32 {
        if let intValue = codingKey.intValue {
            if intValue >= 0 && intValue < columnCount {
                Int32(intValue)
            } else {
                throw Mite3Error.rowReadingError(nil, "column \(codingKey.stringValue) out of range")
            }
        } else if let column = mapUpperColumnNameToIndex[codingKey.stringValue.uppercased()] {
            column
        } else {
            throw Mite3Error.rowReadingError(nil, "Unknown column \(codingKey.stringValue)")
        }
    }
}

fileprivate protocol StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32
    init?(fromStandard reader: Mite3.ColumnReader)
}

extension Mite3.Value: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 {
        switch self {
        case .INTEGER(let value): binder.bind(value)
        case .FLOAT(let value): binder.bind(value)
        case .TEXT(let value): binder.bind(value)
        case .BLOB(let value): binder.bind(value)
        case .NULL: binder.bindNil()
        }
    }

    init?(fromStandard reader: Mite3.ColumnReader) {
        self = switch sqlite3_column_type(reader.pStmt, reader.column) {
        case SQLITE_INTEGER: .INTEGER(reader.readInt64())
        case SQLITE_FLOAT: .FLOAT(reader.readDouble())
        case SQLITE3_TEXT:
            if let string = reader.readString() {
                .TEXT(string)
            } else {
                .NULL
            }
        case SQLITE_BLOB:
            if let data = reader.readData() {
                .BLOB(data)
            } else {
                .NULL
            }
        case SQLITE_NULL:
            .NULL
        default:
            .NULL
        }
    }
}

extension Int8: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readInt8() else { return nil }
        self = value
    }
}

extension UInt8: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readUInt8() else { return nil }
        self = value
    }
}

extension Int16: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readInt16() else { return nil }
        self = value
    }
}

extension UInt16: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readUInt16() else { return nil }
        self = value
    }
}

extension Int32: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        self = reader.readInt32()
    }
}

extension UInt32: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readUInt32() else { return nil }
        self = value
    }
}

extension Int64: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        self = reader.readInt64()
    }
}

extension UInt64: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readUInt64() else { return nil }
        self = value
    }
}

@available(macOS 15.0, *)
@available(macCatalyst 18.0, *)
@available(iOS 18.0, *)
@available(watchOS 11.0, *)
@available(visionOS 2.0, *)
@available(tvOS 18.0, *)
extension Int128: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readInt128() else { return nil }
        self = value
    }
}

@available(macOS 15.0, *)
@available(macCatalyst 18.0, *)
@available(iOS 18.0, *)
@available(watchOS 11.0, *)
@available(visionOS 2.0, *)
@available(tvOS 18.0, *)
extension UInt128: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readUInt128() else { return nil }
        self = value
    }
}

extension Int: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readInt() else { return nil }
        self = value
    }
}

extension UInt: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readUInt() else { return nil }
        self = value
    }
}

extension Bool: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        self = reader.readBool()
    }
}

extension Float: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        self = reader.readFloat()
    }
}

extension Double: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        self = reader.readDouble()
    }
}

extension String: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readString() else { return nil }
        self = value
    }
}

fileprivate let mite3Iso8601LocalMsFormatter: DateFormatter = {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    return df
}()

extension Data: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bind(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        guard let value = reader.readData() else { return nil }
        self = value
    }
}

extension Date: StandardRepresentation {
    func standardBind(binder: Mite3.ParameterBinder) -> Int32 { binder.bindIso8601(self) }

    init?(fromStandard reader: Mite3.ColumnReader) {
        if let value = reader.readIso8601() {
            self = value
        } else {
            return nil
        }
    }
}

fileprivate func mite3ParseIso8601DateTime(string: String) -> Date? {
    if let match = string.firstMatch(of: /^(\d{4})(?:-?(\d{2})(?:-?(\d{2})(?:[ tT]?(\d{2})(?::?(\d{2})(?::?(\d{2})(?:[.,]?(\d+))?)?)?(?:(?:([++±−-])(\d{2})(?::?(\d{2}))?)|([zZ]))?)?)?)?$/) {
        // match 1: year ------------------|           |           |      |        |           |           |              |          |     |       |           |          |
        // match 2: month ------------------------------           |      |        |           |           |              |          |     |       |           |          |
        // match 3, day of month -----------------------------------      |        |           |           |              |          |     |       |           |          |
        // time starts here -----------------------------------------------        |           |           |              |          |     |       |           |          |
        // match 4, hour -----------------------------------------------------------           |           |              |          |     |       |           |          |
        // match 5, minutes --------------------------------------------------------------------           |              |          |     |       |           |          |
        // match 6, seconds (optional within time ----------------------------------------------------------              |          |     |       |           |          |
        // match 7, fractional second digits (optional after seconds) -----------------------------------------------------          |     |       |           |          |
        // time zone offset; hours and minutes, or Z (optional part of time) ---------------------------------------------------------     |       |           |          |
        // match 8, time zone offset sign (optional part of time zone) ---------------------------------------------------------------------       |           |          |
        // match 9, time zone offset hours (optional part of time zone) ----------------------------------------------------------------------------           |          |
        // match 10, time zone offset minutes (optional part of time zone) -------------------------------------------------------------------------------------          |
        // match 11, zulu timezone (optional part of time zone ------------------------------------------------------------------------------------------------------------

        // date
        var components = DateComponents(year: Int(match.1))
        if let monthStr = match.2 {
            components.month = Int(monthStr)
            if let dayStr = match.3 {
                components.day = Int(dayStr)
            }
        }
        
        if let hourStr = match.4 {
            // time
            components.hour = Int(hourStr)
            if let minuteStr = match.5 {
                components.minute = Int(minuteStr)
                if let secondStr = match.6 {
                    components.second = Int(secondStr)
                    if let fractionalSecondsStr = match.7, let fractionalSeconds = Double("0.\(fractionalSecondsStr)") {
                        components.nanosecond = Int(round(fractionalSeconds * 1_000_000_000))
                    }
                }
            }
            
            // time zone, if any
            if let offsetSignStr = match.8, let offsetHoursStr = match.9 {
                let offsetSign = offsetSignStr == "-" || offsetSignStr == "−" ? -1 : 1; // it might be hard to tell, but there's an ASCII hyphen and unicode minus sign
                let offsetHours = Int(offsetHoursStr) ?? 0
                let offsetMinutes = if let offsetMinutesStr = match.10 {
                    Int(offsetMinutesStr) ?? 0
                } else {
                    0
                }
                let offsetSeconds = offsetSign * ((offsetHours * 60) + offsetMinutes) * 60
                components.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
            } else if match.11 != nil {
                components.timeZone = TimeZone(secondsFromGMT: 0) // zulu timezone specified
            }
        }
        
        return Calendar(identifier: .gregorian).date(from: components)
    } else {
        return nil
    }
}

fileprivate struct Mite3IndexedCodingKey: CodingKey {
    let intValue: Int?
    let stringValue: String

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = intValue.description
    }

    init?(stringValue: String) {
        return nil
    }
}

fileprivate struct Mite3ParamsEncoder: Encoder {

    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey : Any]
    let pStmt: OpaquePointer
    
    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(Mite3ParamsKeyedEncodingContainer<Key>(codingPath: codingPath, pStmt: pStmt))
    }
    
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        Mite3ParamsUnkeyedEncodingContainer(codingPath: codingPath, pStmt: pStmt)
   }
    
    func singleValueContainer() -> SingleValueEncodingContainer {
        Mite3ParamsSingleValueEncodingContainer(codingPath: codingPath, pStmt: pStmt)
    }
}

fileprivate struct Mite3ParamsKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    
    let codingPath: [CodingKey]
    let pStmt: OpaquePointer

    mutating func encodeNil(forKey key: Key) throws {
        _ = try mite3ThrowBindError(pStmt: pStmt, Mite3.ParameterBinder(pStmt: pStmt, key: key).bindNil())
    }
    
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        _ = try Mite3.ParameterBinder(pStmt: pStmt, key: key).bind(value)
    }
    
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(Mite3ParamsKeyedEncodingContainer<NestedKey>(codingPath: codingPath + [key], pStmt: pStmt))
    }
    
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        Mite3ParamsUnkeyedEncodingContainer(codingPath: codingPath + [key], pStmt: pStmt)
    }
    
    mutating func superEncoder() -> Encoder {
        Mite3ParamsEncoder(codingPath: codingPath, userInfo: [:], pStmt: pStmt)
    }
    
    mutating func superEncoder(forKey key: Key) -> Encoder {
        Mite3ParamsEncoder(codingPath: codingPath + [key], userInfo: [:], pStmt: pStmt)
    }
}

fileprivate struct Mite3ParamsUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    
    let codingPath: [CodingKey]
    var count: Int = 0
    let pStmt: OpaquePointer

    private mutating func nextSqlite3ParameterIndex() -> Int32 {
        count += 1;
        return Int32(count);
    }

    private mutating func nextCodingKey() -> CodingKey {
        defer { count += 1 }
        return Mite3IndexedCodingKey(intValue: count)!
    }
    
    mutating func encodeNil() throws {
        _ = try mite3ThrowBindError(pStmt: pStmt, Mite3.ParameterBinder(pStmt: pStmt, index: nextSqlite3ParameterIndex()).bindNil())
    }
    
    mutating func encode<T: Encodable>(_ value: T) throws {
        _ = try Mite3.ParameterBinder(pStmt: pStmt, index: nextSqlite3ParameterIndex()).bind(value)
    }

    
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(Mite3ParamsKeyedEncodingContainer<NestedKey>(codingPath: codingPath + [nextCodingKey()], pStmt: pStmt))
    }
    
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        Mite3ParamsUnkeyedEncodingContainer(codingPath: codingPath + [nextCodingKey()], pStmt: pStmt)
    }
    
    mutating func superEncoder() -> Encoder {
        Mite3ParamsEncoder(codingPath: codingPath + [nextCodingKey()], userInfo: [:], pStmt: pStmt)
    }
}

fileprivate struct Mite3ParamsSingleValueEncodingContainer: SingleValueEncodingContainer {

    let codingPath: [CodingKey]
    let pStmt: OpaquePointer

    mutating func encodeNil() throws {
        _ = try mite3ThrowBindError(pStmt: pStmt, Mite3.ParameterBinder(pStmt: pStmt, index: 1).bindNil())
    }
    
    mutating func encode<T: Encodable>(_ value: T) throws {
        _ = try Mite3.ParameterBinder(pStmt: pStmt, index: 1).bind(value)
    }
}

fileprivate struct Mite3RowDecoder: Decoder {
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey : Any]
    let rowReader: StatementRowReader
    
    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key : CodingKey {
        KeyedDecodingContainer(Mite3RowKeyedDecodingContainer<Key>(codingPath: codingPath, rowReader: rowReader))
    }
    
    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        Mite3RowUnkeyedDecodingContainer(codingPath: codingPath, rowReader: rowReader)
    }
    
    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        Mite3RowSingleValueDecodingContainer(codingPath: codingPath, rowReader: rowReader)
    }
}

fileprivate struct Mite3RowKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    
    let codingPath: [CodingKey]
    let allKeys: [Key]
    let rowReader: StatementRowReader
    
    init(codingPath: [CodingKey], rowReader: StatementRowReader) {
        self.codingPath = codingPath
        self.rowReader = rowReader
        self.allKeys = rowReader.columnNames
            .map { Key(stringValue: $0) }
            .filter { $0 != nil }
            .map { $0! }
    }

    func contains(_ key: Key) -> Bool {
        rowReader.contains(key: key)
    }
    
    func decodeNil(forKey key: Key) throws -> Bool {
        try rowReader.readNil(key: key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try rowReader.read(key: key, type: type)
    }
    
    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(Mite3RowKeyedDecodingContainer<NestedKey>(codingPath: codingPath + [key], rowReader: rowReader))
    }
    
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        Mite3RowUnkeyedDecodingContainer(codingPath: codingPath + [key], rowReader: rowReader)
    }
    
    func superDecoder() throws -> any Decoder {
        Mite3RowDecoder(codingPath: codingPath, userInfo: [:], rowReader: rowReader)
    }
    
    func superDecoder(forKey key: Key) throws -> any Decoder {
        Mite3RowDecoder(codingPath: codingPath + [key], userInfo: [:], rowReader: rowReader)
    }
}

fileprivate struct Mite3RowUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    var count: Int?
    let codingPath: [CodingKey]
    var currentIndex: Int
    var isAtEnd: Bool { if let count = count { currentIndex >= count } else { true } }
    let rowReader: StatementRowReader
    
    init(codingPath: [CodingKey], rowReader: StatementRowReader) {
        self.codingPath = codingPath
        self.rowReader = rowReader
        self.count = rowReader.columnCount
        self.currentIndex = 0
    }

    private mutating func nextSqlite3ColumnIndex() -> Int32 {
        defer { currentIndex += 1 }
        return Int32(currentIndex);
    }

    private mutating func nextCodingKey() -> CodingKey {
        defer { currentIndex += 1 }
        return Mite3IndexedCodingKey(intValue: currentIndex)!
    }

    mutating func decodeNil() throws -> Bool {
        try rowReader.readNil(column: nextSqlite3ColumnIndex())
    }

    mutating func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
        try rowReader.read(column: nextSqlite3ColumnIndex(), type: type)
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
        KeyedDecodingContainer(Mite3RowKeyedDecodingContainer<NestedKey>(codingPath: codingPath + [nextCodingKey()], rowReader: rowReader))
    }
    
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        Mite3RowUnkeyedDecodingContainer(codingPath: codingPath + [nextCodingKey()], rowReader: rowReader)
    }
    
    mutating func superDecoder() throws -> any Decoder {
        Mite3RowDecoder(codingPath: codingPath + [nextCodingKey()], userInfo: [:], rowReader: rowReader)
    }
}

fileprivate struct Mite3RowSingleValueDecodingContainer: SingleValueDecodingContainer {

    let codingPath: [CodingKey]
    let rowReader: StatementRowReader
    
    func decodeNil() -> Bool {
        (try? rowReader.readNil(column: 0)) ?? false
    }
    
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        return try rowReader.read(column: 0, type: type)
    }
}

fileprivate struct Mite3Sqlite3ResultCodeInfo {
    let symbol: String
    let comment: String?
}

fileprivate let mite3Sqlite3ResultCodeInfoMap: [Int32: Mite3Sqlite3ResultCodeInfo] = [
    SQLITE_OK: .init(symbol: "SQLITE_OK", comment: "Successful result"),
    SQLITE_ERROR: .init(symbol: "SQLITE_ERROR", comment: "Generic error"),
    SQLITE_INTERNAL: .init(symbol: "SQLITE_INTERNAL", comment: "Internal logic error in SQLite"),
    SQLITE_PERM: .init(symbol: "SQLITE_PERM", comment: "Access permission denied"),
    SQLITE_ABORT: .init(symbol: "SQLITE_ABORT", comment: "Callback routine requested an abort"),
    SQLITE_BUSY: .init(symbol: "SQLITE_BUSY", comment: "The database file is locked"),
    SQLITE_LOCKED: .init(symbol: "SQLITE_LOCKED", comment: "A table in the database is locked"),
    SQLITE_NOMEM: .init(symbol: "SQLITE_NOMEM", comment: "A malloc() failed"),
    SQLITE_READONLY: .init(symbol: "SQLITE_READONLY", comment: "Attempt to write a readonly database"),
    SQLITE_INTERRUPT: .init(symbol: "SQLITE_INTERRUPT", comment: "Operation terminated by sqlite3_interrupt("),
    SQLITE_IOERR: .init(symbol: "SQLITE_IOERR", comment: "Some kind of disk I/O error occurred"),
    SQLITE_CORRUPT: .init(symbol: "SQLITE_CORRUPT", comment: "The database disk image is malformed"),
    SQLITE_NOTFOUND: .init(symbol: "SQLITE_NOTFOUND", comment: "Unknown opcode in sqlite3_file_control()"),
    SQLITE_FULL: .init(symbol: "SQLITE_FULL", comment: "Insertion failed because database is full"),
    SQLITE_CANTOPEN: .init(symbol: "SQLITE_CANTOPEN", comment: "Unable to open the database file"),
    SQLITE_PROTOCOL: .init(symbol: "SQLITE_PROTOCOL", comment: "Database lock protocol error"),
    SQLITE_EMPTY: .init(symbol: "SQLITE_EMPTY", comment: "Internal use only"),
    SQLITE_SCHEMA: .init(symbol: "SQLITE_SCHEMA", comment: "The database schema changed"),
    SQLITE_TOOBIG: .init(symbol: "SQLITE_TOOBIG", comment: "String or BLOB exceeds size limit"),
    SQLITE_CONSTRAINT: .init(symbol: "SQLITE_CONSTRAINT", comment: "Abort due to constraint violation"),
    SQLITE_MISMATCH: .init(symbol: "SQLITE_MISMATCH", comment: "Data type mismatch"),
    SQLITE_MISUSE: .init(symbol: "SQLITE_MISUSE", comment: "Library used incorrectly"),
    SQLITE_NOLFS: .init(symbol: "SQLITE_NOLFS", comment: "Uses OS features not supported on host"),
    SQLITE_AUTH: .init(symbol: "SQLITE_AUTH", comment: "Authorization denied"),
    SQLITE_FORMAT: .init(symbol: "SQLITE_FORMAT", comment: "Not used"),
    SQLITE_RANGE: .init(symbol: "SQLITE_RANGE", comment: "2nd parameter to sqlite3_bind out of range"),
    SQLITE_NOTADB: .init(symbol: "SQLITE_NOTADB", comment: "File opened that is not a database file"),
    SQLITE_NOTICE: .init(symbol: "SQLITE_NOTICE", comment: "Notifications from sqlite3_log()"),
    SQLITE_WARNING: .init(symbol: "SQLITE_WARNING", comment: "Warnings from sqlite3_log()"),
    SQLITE_ROW: .init(symbol: "SQLITE_ROW", comment: "sqlite3_step() has another row ready"),
    SQLITE_DONE: .init(symbol: "SQLITE_DONE", comment: "sqlite3_step() has finished executing"),
    (SQLITE_ERROR | (1<<8)): .init(symbol: "SQLITE_ERROR_MISSING_COLLSEQ", comment: nil),
    (SQLITE_ERROR | (2<<8)): .init(symbol: "SQLITE_ERROR_RETRY", comment: nil),
    (SQLITE_ERROR | (3<<8)): .init(symbol: "SQLITE_ERROR_SNAPSHOT", comment: nil),
    (SQLITE_IOERR | (1<<8)): .init(symbol: "SQLITE_IOERR_READ", comment: nil),
    (SQLITE_IOERR | (2<<8)): .init(symbol: "SQLITE_IOERR_SHORT_READ", comment: nil),
    (SQLITE_IOERR | (3<<8)): .init(symbol: "SQLITE_IOERR_WRITE", comment: nil),
    (SQLITE_IOERR | (4<<8)): .init(symbol: "SQLITE_IOERR_FSYNC", comment: nil),
    (SQLITE_IOERR | (5<<8)): .init(symbol: "SQLITE_IOERR_DIR_FSYNC", comment: nil),
    (SQLITE_IOERR | (6<<8)): .init(symbol: "SQLITE_IOERR_TRUNCATE", comment: nil),
    (SQLITE_IOERR | (7<<8)): .init(symbol: "SQLITE_IOERR_FSTAT", comment: nil),
    (SQLITE_IOERR | (8<<8)): .init(symbol: "SQLITE_IOERR_UNLOCK", comment: nil),
    (SQLITE_IOERR | (9<<8)): .init(symbol: "SQLITE_IOERR_RDLOCK", comment: nil),
    (SQLITE_IOERR | (10<<8)): .init(symbol: "SQLITE_IOERR_DELETE", comment: nil),
    (SQLITE_IOERR | (11<<8)): .init(symbol: "SQLITE_IOERR_BLOCKED", comment: nil),
    (SQLITE_IOERR | (12<<8)): .init(symbol: "SQLITE_IOERR_NOMEM", comment: nil),
    (SQLITE_IOERR | (13<<8)): .init(symbol: "SQLITE_IOERR_ACCESS", comment: nil),
    (SQLITE_IOERR | (14<<8)): .init(symbol: "SQLITE_IOERR_CHECKRESERVEDLOCK", comment: nil),
    (SQLITE_IOERR | (15<<8)): .init(symbol: "SQLITE_IOERR_LOCK", comment: nil),
    (SQLITE_IOERR | (16<<8)): .init(symbol: "SQLITE_IOERR_CLOSE", comment: nil),
    (SQLITE_IOERR | (17<<8)): .init(symbol: "SQLITE_IOERR_DIR_CLOSE", comment: nil),
    (SQLITE_IOERR | (18<<8)): .init(symbol: "SQLITE_IOERR_SHMOPEN", comment: nil),
    (SQLITE_IOERR | (19<<8)): .init(symbol: "SQLITE_IOERR_SHMSIZE", comment: nil),
    (SQLITE_IOERR | (20<<8)): .init(symbol: "SQLITE_IOERR_SHMLOCK", comment: nil),
    (SQLITE_IOERR | (21<<8)): .init(symbol: "SQLITE_IOERR_SHMMAP", comment: nil),
    (SQLITE_IOERR | (22<<8)): .init(symbol: "SQLITE_IOERR_SEEK", comment: nil),
    (SQLITE_IOERR | (23<<8)): .init(symbol: "SQLITE_IOERR_DELETE_NOENT", comment: nil),
    (SQLITE_IOERR | (24<<8)): .init(symbol: "SQLITE_IOERR_MMAP", comment: nil),
    (SQLITE_IOERR | (25<<8)): .init(symbol: "SQLITE_IOERR_GETTEMPPATH", comment: nil),
    (SQLITE_IOERR | (26<<8)): .init(symbol: "SQLITE_IOERR_CONVPATH", comment: nil),
    (SQLITE_IOERR | (27<<8)): .init(symbol: "SQLITE_IOERR_VNODE", comment: nil),
    (SQLITE_IOERR | (28<<8)): .init(symbol: "SQLITE_IOERR_AUTH", comment: nil),
    (SQLITE_IOERR | (29<<8)): .init(symbol: "SQLITE_IOERR_BEGIN_ATOMIC", comment: nil),
    (SQLITE_IOERR | (30<<8)): .init(symbol: "SQLITE_IOERR_COMMIT_ATOMIC", comment: nil),
    (SQLITE_IOERR | (31<<8)): .init(symbol: "SQLITE_IOERR_ROLLBACK_ATOMIC", comment: nil),
    (SQLITE_IOERR | (32<<8)): .init(symbol: "SQLITE_IOERR_DATA", comment: nil),
    (SQLITE_IOERR | (33<<8)): .init(symbol: "SQLITE_IOERR_CORRUPTFS", comment: nil),
    (SQLITE_IOERR | (34<<8)): .init(symbol: "SQLITE_IOERR_IN_PAGE", comment: nil),
    (SQLITE_LOCKED |  (1<<8)): .init(symbol: "SQLITE_LOCKED_SHAREDCACHE", comment: nil),
    (SQLITE_LOCKED |  (2<<8)): .init(symbol: "SQLITE_LOCKED_VTAB", comment: nil),
    (SQLITE_BUSY   |  (1<<8)): .init(symbol: "SQLITE_BUSY_RECOVERY", comment: nil),
    (SQLITE_BUSY   |  (2<<8)): .init(symbol: "SQLITE_BUSY_SNAPSHOT", comment: nil),
    (SQLITE_BUSY   |  (3<<8)): .init(symbol: "SQLITE_BUSY_TIMEOUT", comment: nil),
    (SQLITE_CANTOPEN | (1<<8)): .init(symbol: "SQLITE_CANTOPEN_NOTEMPDIR", comment: nil),
    (SQLITE_CANTOPEN | (2<<8)): .init(symbol: "SQLITE_CANTOPEN_ISDIR", comment: nil),
    (SQLITE_CANTOPEN | (3<<8)): .init(symbol: "SQLITE_CANTOPEN_FULLPATH", comment: nil),
    (SQLITE_CANTOPEN | (4<<8)): .init(symbol: "SQLITE_CANTOPEN_CONVPATH", comment: nil),
    (SQLITE_CANTOPEN | (5<<8)): .init(symbol: "SQLITE_CANTOPEN_DIRTYWAL", comment: "Not Used"),
    (SQLITE_CANTOPEN | (6<<8)): .init(symbol: "SQLITE_CANTOPEN_SYMLINK", comment: nil),
    (SQLITE_CORRUPT | (1<<8)): .init(symbol: "SQLITE_CORRUPT_VTAB", comment: nil),
    (SQLITE_CORRUPT | (2<<8)): .init(symbol: "SQLITE_CORRUPT_SEQUENCE", comment: nil),
    (SQLITE_CORRUPT | (3<<8)): .init(symbol: "SQLITE_CORRUPT_INDEX", comment: nil),
    (SQLITE_READONLY | (1<<8)): .init(symbol: "SQLITE_READONLY_RECOVERY", comment: nil),
    (SQLITE_READONLY | (2<<8)): .init(symbol: "SQLITE_READONLY_CANTLOCK", comment: nil),
    (SQLITE_READONLY | (3<<8)): .init(symbol: "SQLITE_READONLY_ROLLBACK", comment: nil),
    (SQLITE_READONLY | (4<<8)): .init(symbol: "SQLITE_READONLY_DBMOVED", comment: nil),
    (SQLITE_READONLY | (5<<8)): .init(symbol: "SQLITE_READONLY_CANTINIT", comment: nil),
    (SQLITE_READONLY | (6<<8)): .init(symbol: "SQLITE_READONLY_DIRECTORY", comment: nil),
    (SQLITE_ABORT | (2<<8)): .init(symbol: "SQLITE_ABORT_ROLLBACK", comment: nil),
    (SQLITE_CONSTRAINT | (1<<8)): .init(symbol: "SQLITE_CONSTRAINT_CHECK", comment: nil),
    (SQLITE_CONSTRAINT | (2<<8)): .init(symbol: "SQLITE_CONSTRAINT_COMMITHOOK", comment: nil),
    (SQLITE_CONSTRAINT | (3<<8)): .init(symbol: "SQLITE_CONSTRAINT_FOREIGNKEY", comment: nil),
    (SQLITE_CONSTRAINT | (4<<8)): .init(symbol: "SQLITE_CONSTRAINT_FUNCTION", comment: nil),
    (SQLITE_CONSTRAINT | (5<<8)): .init(symbol: "SQLITE_CONSTRAINT_NOTNULL", comment: nil),
    (SQLITE_CONSTRAINT | (6<<8)): .init(symbol: "SQLITE_CONSTRAINT_PRIMARYKEY", comment: nil),
    (SQLITE_CONSTRAINT | (7<<8)): .init(symbol: "SQLITE_CONSTRAINT_TRIGGER", comment: nil),
    (SQLITE_CONSTRAINT | (8<<8)): .init(symbol: "SQLITE_CONSTRAINT_UNIQUE", comment: nil),
    (SQLITE_CONSTRAINT | (9<<8)): .init(symbol: "SQLITE_CONSTRAINT_VTAB", comment: nil),
    (SQLITE_CONSTRAINT | (10<<8)): .init(symbol: "SQLITE_CONSTRAINT_ROWID", comment: nil),
    (SQLITE_CONSTRAINT | (11<<8)): .init(symbol: "SQLITE_CONSTRAINT_PINNED", comment: nil),
    (SQLITE_CONSTRAINT | (12<<8)): .init(symbol: "SQLITE_CONSTRAINT_DATATYPE", comment: nil),
    (SQLITE_NOTICE | (1<<8)): .init(symbol: "SQLITE_NOTICE_RECOVER_WAL", comment: nil),
    (SQLITE_NOTICE | (2<<8)): .init(symbol: "SQLITE_NOTICE_RECOVER_ROLLBACK", comment: nil),
    (SQLITE_NOTICE | (3<<8)): .init(symbol: "SQLITE_NOTICE_RBU", comment: nil),
    (SQLITE_WARNING | (1<<8)): .init(symbol: "SQLITE_WARNING_AUTOINDEX", comment: nil),
    (SQLITE_AUTH | (1<<8)): .init(symbol: "SQLITE_AUTH_USER", comment: nil),
    (SQLITE_OK | (1<<8)): .init(symbol: "SQLITE_OK_LOAD_PERMANENTLY", comment: nil),
    (SQLITE_OK | (2<<8)): .init(symbol: "SQLITE_OK_SYMLINK", comment: "internal use only"),
]
