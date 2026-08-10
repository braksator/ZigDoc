//! Module with several small sibling structs, each holding its own
//! nested decls, to exercise the compact two-member container shape
//! repeatedly and at some depth.

/// First small container.
pub const Alpha = struct {
    /// A constant on Alpha.
    pub const one = 1;
    /// Another constant on Alpha.
    pub const two = 2;
};

/// Second small container.
pub const Beta = struct {
    /// A function on Beta.
    pub fn double(x: i32) i32 {
        return x * 2;
    }
};

/// Third small container, nested two levels deep.
pub const Gamma = struct {
    /// Nested inside Gamma.
    pub const Delta = struct {
        /// A constant on Delta.
        pub const value = 3;
        /// A function on Delta.
        pub fn triple(x: i32) i32 {
            return x * 3;
        }
    };
};
