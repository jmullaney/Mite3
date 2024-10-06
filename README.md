Provides utilities for calling sqlite3 from Swift.

This library is specifically intended to *not* wrap sqlite3 (which already has a carefully designed, documented and maintained API)
but instead to provide utilities to make it easier and more convenient to use from Swift and reduce common boilerplate code.

### Result Code Utilities ###

These are functions to convert the result of calling an sqlite3 API function to a thrown error when the result is an error, or to a
success/failure Result<S,F>.

The errors generated contain extended information about the error. This is pulled from sqlite3_errstr() and, when the database
connection is provided, sqlite3_errmsg(). The symbolic name of the code is also provided, as well as code comments from
the sqlite3 source code (it's possible for these to get out-of-date, though the symbols tend to be stable).

### exec/query ###

These functions execute SQL statements on a database connection.

Parameters can be specified as Encodable values and the results are returned as a Decodable type.

A simple Encodable value can be specified when the statement has one parameter.
Multiple parameters can be passed as an array of Encodable values (when binding by index) or as a
complex Encodable value (whein binding by name).

Likewise, the result type can be a simple Decodable type for statements that return a single column, or an array or object of Decodable
values for statements that return multiple columns.

Use the `exec` variants when you want results returned via callback or don't need results returned.
Use the `query` variants when you want all the result rows returned.
Use the `queryOneOptional` variants when you want at most one row returned. (If the SQL could return multiple rows, the first one is returned.
Use the `queryOne` variants when you want one row returned. (If the SQL could return multiple rows, the first one is returned.) An error occurs if
at least one row isn't returned.

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

### Standard Parameter Binding and Row Reading ###

Certain types have a default paramerer-binding/row-reading form. See below.

- When parameters are specified as a simple value, it binds by index to the first statement parameter.
- When parameters are specified as an array of values, each element is bound by index to the statatement parameters.
- When the the parameters are specified as a complex object, each property is bound by name to the statmenet parameters, using the Encodable coding
  keys as the names.
- When the result row type is a simple value, it's value is read from the first column value
- When the result row type is an array of values, the row is returned as an array of column values.
- When the result row type is a complex object, each property's value is read from the result columns by property name, using the Decodable coding key.

### Standard Forms ###

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

Codable values below the top level are encoded/decoded as JSON using sqlite3's TEXT data type.

### Customizing Parameter Binding and Row Reading ###

You can extend a type to implement `Mite3.CustomRepresentation` to customize how values of
the type are bound as parameters or read as result rows.

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