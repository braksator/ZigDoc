//! Module whose doc comments exercise the markdown dialect.

/// Formats a value using `std.fmt`.
///
/// Supports:
/// - integers
/// - floats
/// - strings
///
/// Example:
/// ```zig
/// const s = format(42);
/// ```
pub fn format(value: i32) i32 {
    return value;
}
