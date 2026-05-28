const std = @import("std");

pub fn SpscRing(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (!std.math.isPowerOfTwo(capacity)) {
            @compileError("SpscRing capacity must be a power of two");
        }
        if (capacity < 2) {
            @compileError("SpscRing capacity must be at least 2");
        }
    }
    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        buf: [capacity]T = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn push(self: *Self, item: T) bool {
            const h = self.head.load(.monotonic);
            const next_h = (h +% 1) & mask;
            if (next_h == self.tail.load(.acquire)) return false;
            self.buf[h] = item;
            self.head.store(next_h, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const t = self.tail.load(.monotonic);
            if (t == self.head.load(.acquire)) return null;
            const item = self.buf[t];
            self.tail.store((t +% 1) & mask, .release);
            return item;
        }

        pub fn hasItem(self: *Self) bool {
            const t = self.tail.load(.monotonic);
            return t != self.head.load(.acquire);
        }
    };
}

test "push and pop preserve order" {
    var ring: SpscRing(u32, 8) = .{};
    try std.testing.expect(ring.push(1));
    try std.testing.expect(ring.push(2));
    try std.testing.expect(ring.push(3));
    try std.testing.expectEqual(@as(?u32, 1), ring.pop());
    try std.testing.expectEqual(@as(?u32, 2), ring.pop());
    try std.testing.expectEqual(@as(?u32, 3), ring.pop());
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}

test "drops when full" {
    var ring: SpscRing(u32, 4) = .{};
    try std.testing.expect(ring.push(1));
    try std.testing.expect(ring.push(2));
    try std.testing.expect(ring.push(3));
    try std.testing.expect(!ring.push(4));
}
