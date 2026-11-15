import Foundation

func lintProof() {
    _ = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/x"))
    // swiftlint:disable:next try_optional
    let ok = 1
    // SHORTCUT: skip validation for now.
    _ = ok
    // SHORTCUT: skip validation for now, fine. Revisit when sync ships.
    // a comment mentioning try? must not fire
    let s = "try? in a string must not fire"
    _ = s
}
