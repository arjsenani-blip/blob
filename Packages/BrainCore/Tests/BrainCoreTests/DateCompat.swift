import Foundation

// Xcode 27.2's SDK declares Date's own <= and >=, but the macOS 27.2 beta's Foundation doesn't ship them,
// so any `date >= other` crashed at launch (a jump to a missing function). These versions are built from <,
// which every Foundation has; this module's code uses them instead. Safe to delete once the OS catches up.
extension Date {
    static func <= (l: Date, r: Date) -> Bool { !(r < l) }
    static func >= (l: Date, r: Date) -> Bool { !(l < r) }
}
