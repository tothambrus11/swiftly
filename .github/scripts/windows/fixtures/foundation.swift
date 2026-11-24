import Foundation
#if canImport(FoundationEssentials)
import FoundationEssentials
#endif

struct Item: Codable, Equatable { let name: String; let count: Int; let when: Date }
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys]
enc.dateEncodingStrategy = .iso8601
let items = [Item(name: "apple", count: 3, when: Date(timeIntervalSince1970: 0))]
let data = try enc.encode(items)
let json = String(decoding: data, as: UTF8.self)
print("JSON:", json)
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let decoded = try dec.decode([Item].self, from: data)
precondition(decoded == items)

// FileManager + URL + Data
let fm = FileManager.default
let url = fm.temporaryDirectory.appendingPathComponent("portable-swift-\(ProcessInfo.processInfo.processIdentifier).txt")
try data.write(to: url)
let readBack = try Data(contentsOf: url)
precondition(readBack == data)
precondition(fm.fileExists(atPath: url.path))
try fm.removeItem(at: url)
let u = URL(string: "https://swift.org/install?platform=windows")!
print("URL host:", u.host ?? "?", "query:", u.query ?? "?")
print("base64:", Data([1, 2, 3, 255]).base64EncodedString())

// String(format:), formatters (FoundationInternationalization / ICU data)
print(String(format: "pi=%.3f hex=%x str=%@", 3.14159, 255, "ok" as NSString))
let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = "yyyy-MM-dd HH:mm"
print("DateFormatter:", df.string(from: Date(timeIntervalSince1970: 86400 * 365)))
let nf = NumberFormatter(); nf.numberStyle = .decimal; nf.locale = Locale(identifier: "en_US")
print("NumberFormatter:", nf.string(from: 1234567.891) ?? "?")
print("Date.now formatted:", Date.now.formatted(date: .abbreviated, time: .omitted))
print("UUID:", UUID().uuidString.count, "cwd:", fm.currentDirectoryPath)
print("FOUNDATION OK")
