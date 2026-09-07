//! Fixture reproducing a crash where a filename mention's byte offset
//! (valid against the whole decl source) was wrongly reused against the
//! much shorter `signature` string.

/// A struct whose doc comment mentions codelink_mention_target.zig deep
/// into a long block of prose, well past where this struct's own short
/// one-line signature would end if the mention's offset were reused there.
pub const Fe = struct {
    x: u64 = 0,
};
