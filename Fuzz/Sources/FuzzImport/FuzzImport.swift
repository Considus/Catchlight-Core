//
//  FuzzImport.swift — libFuzzer target: Markdown / plain-text import.
//
//  The input is a file the user drops in: `TakeImporter.parseDocument` (which reaches
//  the `<!-- catchlight:data` JSON block and `TakeTransfer.decoder()` when the input
//  starts with the export frontmatter) and the single-Take `parse`.
//

import Foundation
import CatchlightCore
import FuzzSupport

private let fileDate = Date(timeIntervalSince1970: 1_780_000_000)

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzImport(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let text = String(decoding: fuzzData(start, count), as: UTF8.self)
    _ = TakeImporter.parseDocument(text, fileDate: fileDate)
    _ = TakeImporter.parse(text, fileDate: fileDate)
    return 0
}
