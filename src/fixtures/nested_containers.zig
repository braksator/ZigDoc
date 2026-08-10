//! Module with a struct containing a nested struct.

/// Outer container.
pub const Outer = struct {
    /// Inner container, nested inside Outer.
    pub const Inner = struct {
        /// A documented constant on the inner struct.
        pub const value = 42;
    };
};
