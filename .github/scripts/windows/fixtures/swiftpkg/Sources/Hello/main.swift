import Foundation
import HelloLib

struct Msg: Codable { let text: String; let at: Date }
let data = try JSONEncoder().encode(Msg(text: greeting("SwiftPM"), at: Date()))
print(String(decoding: data, as: UTF8.self))
print(String(format: "%.2f", 2.0.squareRoot()))
print("SWIFTPM OK")
