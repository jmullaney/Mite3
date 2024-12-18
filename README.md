Utilities to make it easier and more convenient to use sqlite3 from Swift and
reduce related boilerplate code.

Note: this is specifically intended to <u>not</u> wrap sqlite3. That makes this useful for, e.g., creating an application-level data access wrapper
around sqlite where an intermediate wrapper would ultimately get in the way more than help.

| | |
|-|-|
| Result Code Utilities | convert the result of calling an sqlite3 API function to a thrown error when the result is an error, or to a success/failure `Result<S,F>`. |
| `exec()` / `query()` / `get()` / `getOptional()` | Execute SQL statments on a database connection. Accepts `Encodable` values for parameters, and any `Decodable` for results. |
| `queryInt()` / `getOptionalInt()` / `queryString()` / `getOptionalString()` | Convenient variants of get() and getOptional() that return a specific type of value. |
| Binding and reading to/from statements | Use the same `Codable`-based parameter binding and row reading that the `exec` and `query*` functions provide, but directly on sqlite3 statements prepared outside of Mite3.|
| `Mite3.Value` utility type| A variant type capable of directly representing sqlite3 fundamental data types. |
| `Mite3.CustomRepresentation` | Customizing how Mite3 binds/reads values to/from statements. |

### Usage Examples ###


```swift
    var pDb: OpaquePointer! = nil
    try Mite3.call { sqlite3_open(":memory:", &pDb) }
    defer { sqlite3_close(pDb) }

    try Mite3.exec(pDb: pDb, sql: "CREATE TABLE user (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
    try Mite3.exec(pDb: pDb,
        sql: "INSERT INTO user(name) VALUES (?), (?), (?)",
        params: ["John Smith", "Annie Oakley", "Jerry West"]
    )

    let jUsers = try Mite3.query(pDb: pDb,
        sql: "SELECT id, name FROM user WHERE name like ? ORDER BY name",
        params: "J%",
        type: User.self
    )
    print(jUsers) // output: [{"id":3,"name":"Jerry West"}, {"id":1,"name":"John Smith"}]

    let aRowOfValues = try Mite3.get(pDb: pDb,
        sql: "SELECT datetime('2024-10-03 10:11:12') someDate, 1+2+3 someNum, 'abc' someStr",
        type: [Mite3.Value].self
    )
    print(aRowOfValues[0]) // output: 2024-10-03 10:11:12
    print(aRowOfValues[1]) // output: 6
    print(aRowOfValues[2]) // output: abc

    struct User: Codable, CustomStringConvertible {
        let id: Int
        let name: String
        let notes: String?
        var description: String { String(data: try! JSONEncoder().encode(self), encoding: .utf8)! }
    }
```

### Result Code Utilities ###

These are functions to convert the result of calling an sqlite3 API function to a thrown error when
the result is an error, or to a success/failure `Result<S,F>`.

The errors generated contain extended information about the error. This is pulled from sqlite3_errstr() and, when the database
connection is provided, sqlite3_errmsg(). The symbolic name of the code is also provided, as well as code comments from
the sqlite3 source code (it's possible for these to get out-of-date, though the symbols tend to be stable).

### exec/query ###

These functions execute SQL statements on a database connection.

Parameters can be specified as Encodable values and the results are returned as a Decodable type.

- Use the `exec` variants without callback when you don't need results returned.
- Use the `exec` variants with callback when you want results returned via callback.
- Use the `query` variants when you want all the result rows returned.
- Use the `get` variants when you want one row returned. (If the SQL could return multiple rows, the first one is returned.) An error occurs if
  at least one row isn't returned.
- Use the `getOptional` variants when you want at most one row returned. (If the SQL could return multiple rows, the first one is returned.

### Binding Parameters and Reading Rows Directly to/from Statemenets ###

`Mite3.bindParameters()` lets you bind parameters from Decodable values in the same way as `exec` and `query*`, but you
can do it directly on an sqlite3 statement pointer. This lets you use the Mite3 binding on a statement you prepare outside of Mite3.

`Mite3.readRow()` lets you read the current row to an Encodable type in the same way as `exec` and `query*`, but you
can do it directly from an sqlite3 statement pointer. You would use this when you're preparing your statement and calling
`sqlite3_step()` outside of Mite3, but still want to use its row reading mechanism.

### Utility Types ###

`Mite3.Value`

This is a variant value corresponding to the five sqlite3 fundamental data types.
See https://www.sqlite.org/c3ref/c_blob.html

- .INTEGER corresponds to SQLITE_INTEGER. The value is Int64
- .FLOAT corresponds to SQLITE_FLOAT. The value is Double
- .TEXT corresponds to SQLITE_3_TEXT. The value is String
- .BLOB correspionds to SQLITE_BLOB. The value is Data
- .NULL corresponds to SQLITE_NULL. There is no stored value, but you can consider nil the implicit value.

This can be useful for receiving arbitrary values in a form the same as or losslessly converted from the form sqlite3 uses.
E.g., you can use [Mite3.Value].self as the result type for any query, and receive whatever values sqlite3 provides.

### Parameter Binding and Row Reading ###

Functions accept SQL parameters through a variadic `params: Encodable...` parameter.
This means you can specify zero, one, or more SQL parameters, as needed by the SQL being
executed.

- Certain common types have a standard binding (see below). These are accepted as-is, and
  are bound by index to SQL parameters.
- When an array value is specified directly, its elements are bound by index to SQL parameters.
  Extra values are ignored.
- When an object/struct is specified, its properties are bound by name, case-insensitive, to SQL
  paramerers, using the object's `Encodable` coding keys as named. Extra properties -- those
  that don't correspond to a SQL parameter -- are ignored.
- Types can implement  `Mite3.CustomRepresentation` to customize how its values
  are bound as a sqlite parameter (see below).

Note: since `params` is variadic, multiple arrays and objects may be specified. In that case, values
bound from later arrays and objects overwrite values bound from earlier ones. (Use this capability
carefully, since it's confusing and usually not necessary.)

Note 2: values nested in an array or object that don't have a standard or custom representation
are serialized using a JSONEncoder.

Results are converted to Swift types that implement `Decodable`.

- When the result row type is a simple value, it's value is read from the first column value
- When the result row type is an array of values, the row is returned as an array of column values.
- When the result row type is a complex object, each property's value is read from the result columns by
  property name (case-insensitive), using the Decodable coding key.

### Standard Binding/Reading ###

    | Swift Type | sqlite3 data type               |
    | Int8       | INTEGER (64-bit integer)        |
    | UInt8      | INTEGER (64-bit integer)        |
    | Int16      | INTEGER (64-bit integer)        |
    | UInt16     | INTEGER (64-bit integer)        |
    | Int32      | INTEGER (64-bit integer)        |
    | UInt32     | INTEGER (64-bit integer)        |
    | Int64      | INTEGER (64-bit integer)        |
    | UInt64     | TEXT                            |
    | Int128     | TEXT                            |
    | UInt128    | TEXT                            |
    | Int        | INTEGER (64-bit integer)        |
    | UInt       | TEXT                            |
    | Bool       | 0 or 1 INTEGER (64-bit integer) |
    | Float      | FLOAT (64-bit floating point)   |
    | Double     | FLOAT (64-bit floating point)   |
    | String     | TEXT                            |
    | Data       | BLOB (bytes)                    |
    | Date       | as ISO 8601 date/time as TEXT   |

Nested `Codable` values are encoded/decoded as JSON as use sqlite3's TEXT data type.

### Customizing Parameter Binding and Row Reading ###

You can extend a type to implement `Mite3.CustomRepresentation` to customize how values of
the type are bound as parameters or read as result row column values.

`func bind(binder: ParameterBinder) -> Int32` determins how a value is bound as a parameter.
The ParameterBinder instance passed in provides utilities for binding various kinds of primitive values in a typical way.
You can use these utility functions or directly use the sqlite3 binding APIs on statement pointer however needed.

`init?(from reader: ColumnReader)` determines how a value is read.
The ColumnReader instance passed in provides utilities for reads various kinds of primitive values in a typical way.
You can use these utility functions or directly use the sqlite3 column APIs on the statement pointer however needed.

As an alternative to  `Mite3.CustomRepresentation`, you can customize a type's Ecodable and Decodable
implenentation (unless it already has a standard form, as mentioned above). Note that CustomRepresentation has
precedence over the Codable implementation.

### Mite3.Connection ###

Provides an OO-style interface as an alternative to the functions that take a database pointer as the first parameter.
