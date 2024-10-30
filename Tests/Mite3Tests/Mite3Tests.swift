import Testing
@testable import Mite3
import Foundation
import SQLite3

// TODO: tests are woeful

struct SubRow: Codable {
    let prop: String
    let val: String
}

struct TestRow: Codable {
    let id: Int
    let name: String
    var props: [SubRow]?
}

@Test func adHocTests() async throws {
    let filePath = ":memory:"
    var pDb: OpaquePointer? = nil
    
    #expect(throws: Mite3Error.self) {
        try Mite3.call { sqlite3_open_v2("can't work://can/it?", &pDb, SQLITE_OPEN_READONLY, nil) }
    }
    
    try Mite3.call { sqlite3_open(filePath, &pDb) }
    guard let pDb = pDb else { throw Mite3Error(code: SQLITE_ERROR) }
    defer { sqlite3_close(pDb) }
    
    // some exec scenarios
    do {
        try Mite3.exec(pDb: pDb, sql: "CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, props BLOB)")
        try Mite3.exec(pDb: pDb, sql: "INSERT INTO test(name) VALUES (?), (?), (?), (?)", params: ["aaa", "bbb", "ccc", "aaa2"])
        var output: [String] = .init()
        try Mite3.exec(pDb: pDb, sql: "SELECT id, name FROM test WHERE name like ? ORDER BY id", params: "a%", callback: { (row: TestRow) -> Bool in
            output.append("A row: id = \(row.id), name = \"\(row.name)\", props = \(String(describing: row.props))")
            return true
        })
        #expect(output == ["A row: id = 1, name = \"aaa\", props = nil", "A row: id = 4, name = \"aaa2\", props = nil"])
    }
    
    // more exec scenarios, encoding/decoding complex column value
    let someProps = [SubRow(prop: "a", val: "b"), SubRow(prop: "c", val: "d")]
    let somePropsData = try JSONEncoder().encode(someProps)
    do {
        try Mite3.exec(pDb: pDb, sql: "INSERT INTO test(name, props) VALUES ('aaa3', ?)", params: [somePropsData])
        var output: [String] = .init()
        try Mite3.exec(pDb: pDb, sql: "SELECT id, name, props FROM test WHERE name like ? ORDER BY id", params: "a%", "b", callback: { (row: TestRow) -> Bool in
            let propsDesc = if let props = row.props {
                props.description
            } else {
                "nil"
            }
            output.append("B row: id = \(row.id), name = \"\(row.name)\", props = \(propsDesc)")
            return true
        })
        #expect(output == [
            "B row: id = 1, name = \"aaa\", props = nil",
            "B row: id = 4, name = \"aaa2\", props = nil",
            "B row: id = 5, name = \"aaa3\", props = [Mite3Tests.SubRow(prop: \"a\", val: \"b\"), Mite3Tests.SubRow(prop: \"c\", val: \"d\")]"
        ])
    }
    
    // basic query scenario
    do {
        var output: [String] = .init()
        for row in try Mite3.query(pDb: pDb, sql: "SELECT id, name, props FROM test WHERE name like ? ORDER BY id", params: ["a%", "b"], type: [Mite3.Value].self) {
            output.append("C row: \(row)")
        }
        #expect(output == [
            "C row: [1, aaa, NULL]",
            "C row: [4, aaa2, NULL]",
            "C row: [5, aaa3, \(String(describing: [UInt8](somePropsData)))]"
        ])
    }
    
    // basic query scenario - two params directly
    do {
        var output: [String] = .init()
        for row in try Mite3.query(pDb: pDb, sql: "SELECT id, name FROM test WHERE (name like ? or name like ?) AND props IS NULL ORDER BY id", params: "a%", "b%", type: [Mite3.Value].self) {
            output.append("D1 row: \(row)")
        }
        #expect(output == [
            "D1 row: [1, aaa]",
            "D1 row: [2, bbb]",
            "D1 row: [4, aaa2]",
        ])
    }

    // basic query scenario - two params in an array
    do {
        var output: [String] = .init()
        for row in try Mite3.query(pDb: pDb, sql: "SELECT id, name FROM test WHERE (name like ? or name like ?) AND props IS NULL ORDER BY id", params: ["a%", "b%"], type: [Mite3.Value].self) {
            output.append("D1 row: \(row)")
        }
        #expect(output == [
            "D1 row: [1, aaa]",
            "D1 row: [2, bbb]",
            "D1 row: [4, aaa2]",
        ])
    }

    // basic query scenario - two params in an object
    do {
        struct MyParams: Codable { let paramA: String; let paramB: String; let paramC: String }
        var output: [String] = .init()
        for row in try Mite3.query(pDb: pDb, sql: "SELECT id, name FROM test WHERE (name like :paramA or name like :paramB) AND props IS NULL ORDER BY id", params: MyParams(paramA: "a%", paramB: "b%", paramC: "c%"), type: [Mite3.Value].self) {
            output.append("D1 row: \(row)")
        }
        #expect(output == [
            "D1 row: [1, aaa]",
            "D1 row: [2, bbb]",
            "D1 row: [4, aaa2]",
        ])
    }

    // basic queryOneOptional scenarios
    do {
        let optValue = try Mite3.queryOptional(pDb: pDb, sql: "SELECT '12313123 33333'", type: Mite3.Value.self)
        #expect(optValue == .some(Mite3.Value.TEXT("12313123 33333")))
        
        let optValue2 = try Mite3.queryOptional(pDb: pDb, sql: "SELECT '12313123 33333' FROM test WHERE 0=1", type: Mite3.Value.self)
        #expect(optValue2 == .none)
    }
    
    // basic queryOne scenarios
    do {
        let value = try Mite3.queryOne(pDb: pDb, sql: "SELECT '12313123 33333'", type: Mite3.Value.self)
        #expect(value == Mite3.Value.TEXT("12313123 33333"))
        
        #expect(throws: Mite3Error.self, performing: {
            try Mite3.queryOne(pDb: pDb, sql: "SELECT '12313123 33333' FROM test WHERE 0=1", type: Mite3.Value.self)
        })
    }

    // Mite3.Value round-trips to JSON
    do {
        let v = [
            Mite3.Value.INTEGER(22),
            Mite3.Value.FLOAT(5.7),
            Mite3.Value.TEXT("Hello, World!"),
            Mite3.Value.BLOB(Data([UInt8](repeating: 65, count: 3))),
            Mite3.Value.NULL,
        ]
        
        let je = JSONEncoder()
        let jsonData = try je.encode(v)
        let json = String(decoding: jsonData, as: Unicode.UTF8.self)
        #expect(json == "[22,5.7,\"Hello, World!\",[65,65,65],null]")
        
        let jd = JSONDecoder()
        let v2 = try jd.decode([Mite3.Value].self, from: jsonData)
        #expect(v2 == v)
        
        let jsonData2 = try je.encode(v2)
        let json2 = String(decoding: jsonData2, as: Unicode.UTF8.self)
        #expect(json2 == "[22,5.7,\"Hello, World!\",[65,65,65],null]")
    }
    
    try Mite3.exec(pDb: pDb, sql: "CREATE TABLE IF NOT EXISTS dtest (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, dvalue TEXT)")

    // date encoded to ISO 8601 with ms
    do {
        let iso8601LocalMsFormatter: DateFormatter = {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
            return df
        }()
        
        func iso8601StringLocalMs(date: Date) -> String {
            return iso8601LocalMsFormatter.string(from: date)
        }
        
        let now = Date()
        try Mite3.exec(pDb: pDb, sql: "INSERT INTO dtest(name, dvalue) VALUES ('date1', ?)", params: now)
        let dValue = try Mite3.queryOne(pDb: pDb, sql: "SELECT dValue FROM dtest WHERE name = 'date1'", type: Mite3.Value.self)
        #expect(dValue.description == iso8601StringLocalMs(date: now))
    }

    // multiple statements, each returning values
    do {
        var output: [String] = .init()
        try Mite3.exec(pDb: pDb, sql: "SELECT id, name FROM test WHERE name like ? ORDER BY id; select 'here I am!'; SELECT 2 name FROM test WHERE name like 'b%'", params: "a%", callback: { (row: [Mite3.Value]) -> Bool in
            output.append("D name = \(row)")
            return true
        })

        #expect(output == [
            "D name = [1, aaa]",
            "D name = [4, aaa2]",
            "D name = [5, aaa3]",
            "D name = [here I am!]",
            "D name = [2]"
        ])
    }

    // multiple statements, second one with error. Results from first statemenr are returned, then an error is thrown
    do {
        var output: [String] = .init()
        #expect(throws: Mite3Error.self) {
            try Mite3.exec(pDb: pDb, sql: "SELECT id, name FROM test WHERE name like ? ORDER BY id; select 1 id, doesnotexist name from test; SELECT id, name FROM test WHERE name like 'b%' ORDER BY id", params: "a%", callback: { (row: [Mite3.Value]) -> Bool in
                output.append("E name = \(row)")
                return true
            })
        }
        #expect(output == [
            "E name = [1, aaa]",
            "E name = [4, aaa2]",
            "E name = [5, aaa3]",
        ])
    }
}
