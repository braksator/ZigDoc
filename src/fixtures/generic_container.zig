//! A generic container type, in its own file, instantiated directly
//! by the root. Its returned struct and that struct's own methods
//! must stay inlined on whichever page instantiates it — none of them
//! is an `@import` boundary in its own right.

/// Generic container over `T`.
pub fn Container(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,

        /// Compare two items.
        fn compare(a: T, b: T) bool {
            return a == b;
        }

        /// Returns the first item.
        pub fn first(self: Self) T {
            return self.items[0];
        }

        /// Nested helper type.
        pub const Iterator = struct {
            /// Advance the iterator.
            pub fn next(self: *@This()) ?T {
                _ = self;
                return null;
            }
        };
    };
}
