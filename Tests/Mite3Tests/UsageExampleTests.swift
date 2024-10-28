//
//  UsageExampleTests.swift
//  Mite3
//
//  Created by jmullaney on 10/6/24.
//
import Testing
@testable import Mite3
import Foundation
import SQLite3

@Test func usageExample1() async throws {
    var pDb: OpaquePointer! = nil
    try Mite3.call { sqlite3_open(":memory:", &pDb) }
    defer { sqlite3_close(pDb) }
    
    try Mite3.exec(pDb: pDb, sql: "CREATE TABLE user (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
    try Mite3.exec(pDb: pDb,
        sql: "INSERT INTO user(name) VALUES (?), (?), (?)",
        params: "John Smith", "Annie Oakley", "Jerry West"
    )
    
    let jUsers = try Mite3.query(pDb: pDb,
        sql: "SELECT id, name FROM user WHERE name like ? ORDER BY name",
        params: "J%",
        type: User.self
    )
    print(jUsers) // output: [{"id":3,"name":"Jerry West"}, {"id":1,"name":"John Smith"}]
    
    let aRowOfValues = try Mite3.queryOne(pDb: pDb,
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
}



