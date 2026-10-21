const std = @import("std");
const builtin = @import("builtin");

const Page = []align(std.heap.page_size_min) u8;
pub const Error = error{ OutOfMemory, InvalidLength, MemoryLockFailed, DontDumpFailed, MemoryProtectionFailed, UnsupportedProtectedMemory, BufferReleased, LockBudgetFailed };

var budget_mutex: std.atomic.Mutex = .unlocked;

/// Explicit per-process Windows setup, called once by the owner before KDF.
/// Raises (never lowers/restores) this process's working-set minimum, allowing
/// up to 64 MiB of concurrently locked regions plus 4 MiB of OS headroom.
/// This does not reserve/guarantee locks: each Buffer still checks VirtualLock.
/// Linux limits are provisioned by the supervisor, never changed here.
pub fn configureNativeLockBudget(bytes: usize) Error!void {
    if (bytes == 0 or bytes > 64 * 1024 * 1024) return error.LockBudgetFailed;
    if (builtin.os.tag != .windows) return error.UnsupportedProtectedMemory;
    while (!budget_mutex.tryLock()) std.atomic.spinLoopHint();
    defer budget_mutex.unlock();
    var minimum: usize = 0;
    var maximum: usize = 0;
    const process = std.os.windows.GetCurrentProcess();
    if (Win.GetProcessWorkingSetSize(process, &minimum, &maximum) == 0) return error.LockBudgetFailed;
    const desired_minimum = @max(minimum, bytes + 4 * 1024 * 1024);
    const desired_maximum = @max(maximum, desired_minimum + 4 * 1024 * 1024);
    if (desired_minimum == minimum and desired_maximum == maximum) return;
    if (Win.SetProcessWorkingSetSize(process, desired_minimum, desired_maximum) == 0) return error.LockBudgetFailed;
}

/// Injectable only through initForTesting. Production always selects Native.
pub const Backend = struct {
    context: *anyopaque,
    allocate: *const fn (*anyopaque, usize) Error!Page,
    lock: *const fn (*anyopaque, Page) Error!void,
    dontDump: *const fn (*anyopaque, Page) Error!void,
    protect: *const fn (*anyopaque, Page, bool) Error!void,
    unlock: *const fn (*anyopaque, Page) void,
    release: *const fn (*anyopaque, Page) void,
};

pub const Report = struct { locked: bool, dont_dump: bool, read_only: bool };

/// Owns a dedicated mapping. Never copy an initialized Buffer. Borrowed slices
/// must not escape its lifetime, nor survive a freeze/write transition.
pub const Buffer = struct {
    storage: Page,
    length: usize,
    backend: Backend,
    protection: Report,

    pub fn init(length: usize) Error!Buffer {
        return create(length, Native.backend());
    }

    pub fn initForTesting(length: usize, backend: Backend) Error!Buffer {
        if (!builtin.is_test) @compileError("protected memory test backend is test-only");
        return create(length, backend);
    }

    fn create(length: usize, backend: Backend) Error!Buffer {
        const page_size = std.heap.pageSize();
        if (length == 0 or length > std.math.maxInt(usize) - page_size) return error.InvalidLength;
        const storage = try backend.allocate(backend.context, std.mem.alignForward(usize, length, page_size));
        var locked = false;
        errdefer {
            // No caller receives this mapping until all protections succeed.
            std.crypto.secureZero(u8, storage);
            if (locked) backend.unlock(backend.context, storage);
            backend.release(backend.context, storage);
        }
        try backend.lock(backend.context, storage);
        locked = true;
        try backend.dontDump(backend.context, storage);
        try backend.protect(backend.context, storage, false);
        // Initialization occurs only after protections, including write access.
        @memset(storage, 0);
        return .{ .storage = storage, .length = length, .backend = backend, .protection = .{
            .locked = true,
            .dont_dump = builtin.os.tag == .linux,
            .read_only = false,
        } };
    }

    pub fn bytes(self: *const Buffer) []const u8 {
        std.debug.assert(self.length != 0);
        return self.storage[0..self.length];
    }

    pub fn writable(self: *Buffer) Error![]u8 {
        if (self.length == 0) return error.BufferReleased;
        if (self.protection.read_only) {
            try self.backend.protect(self.backend.context, self.storage, false);
            self.protection.read_only = false;
        }
        return self.storage[0..self.length];
    }

    pub fn freeze(self: *Buffer) Error!void {
        if (self.length == 0) return error.BufferReleased;
        if (!self.protection.read_only) {
            try self.backend.protect(self.backend.context, self.storage, true);
            self.protection.read_only = true;
        }
    }

    pub fn report(self: *const Buffer) Report {
        return self.protection;
    }

    pub fn deinit(self: *Buffer) void {
        if (self.length == 0) return;
        if (self.protection.read_only) {
            self.backend.protect(self.backend.context, self.storage, false) catch
                @panic("cannot restore protected memory for secure erase");
        }
        std.crypto.secureZero(u8, self.storage);
        self.backend.unlock(self.backend.context, self.storage);
        self.backend.release(self.backend.context, self.storage);
        self.length = 0;
        self.protection = .{ .locked = false, .dont_dump = false, .read_only = false };
    }
};

const Native = struct {
    var context: u8 = 0;
    var linux_lock_mutex: std.atomic.Mutex = .unlocked;
    var linux_locked_bytes: usize = 0;
    fn backend() Backend {
        return .{ .context = &context, .allocate = allocate, .lock = lock, .dontDump = dontDump, .protect = protect, .unlock = unlock, .release = release };
    }
    fn allocate(_: *anyopaque, length: usize) Error!Page {
        if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.UnsupportedProtectedMemory;
        return std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), length);
    }
    fn lock(_: *anyopaque, storage: Page) Error!void {
        switch (builtin.os.tag) {
            .linux => {
                // WSL1 may report mlock success while ignoring RLIMIT_MEMLOCK.
                // Account this module's mappings explicitly as well as asking
                // the kernel (which also accounts other libraries' mappings).
                while (!linux_lock_mutex.tryLock()) std.atomic.spinLoopHint();
                defer linux_lock_mutex.unlock();
                const limit = std.posix.getrlimit(.MEMLOCK) catch return error.MemoryLockFailed;
                if (linux_locked_bytes > limit.cur or storage.len > limit.cur - linux_locked_bytes) return error.MemoryLockFailed;
                std.process.lockMemory(storage, .{}) catch return error.MemoryLockFailed;
                linux_locked_bytes += storage.len;
            },
            .windows => if (Win.VirtualLock(storage.ptr, storage.len) == 0) return error.MemoryLockFailed,
            else => return error.UnsupportedProtectedMemory,
        }
    }
    fn dontDump(_: *anyopaque, storage: Page) Error!void {
        if (builtin.os.tag == .linux) {
            std.posix.madvise(storage.ptr, storage.len, std.os.linux.MADV.DONTDUMP) catch return error.DontDumpFailed;
        }
    }
    fn protect(_: *anyopaque, storage: Page, read_only: bool) Error!void {
        std.process.protectMemory(storage, .{ .read = true, .write = !read_only }) catch return error.MemoryProtectionFailed;
    }
    fn unlock(_: *anyopaque, storage: Page) void {
        switch (builtin.os.tag) {
            .linux => {
                while (!linux_lock_mutex.tryLock()) std.atomic.spinLoopHint();
                defer linux_lock_mutex.unlock();
                // A failed unlock retains the accounting charge. Never claim
                // a reusable budget while kernel lock ownership is uncertain.
                std.process.unlockMemory(storage) catch return;
                linux_locked_bytes -= storage.len;
            },
            .windows => _ = Win.VirtualUnlock(storage.ptr, storage.len),
            else => {},
        }
    }
    fn release(_: *anyopaque, storage: Page) void {
        std.heap.page_allocator.free(storage);
    }
};

const Win = struct {
    extern "kernel32" fn VirtualLock(*const anyopaque, usize) callconv(.winapi) i32;
    extern "kernel32" fn VirtualUnlock(*const anyopaque, usize) callconv(.winapi) i32;
    extern "kernel32" fn GetProcessWorkingSetSize(std.os.windows.HANDLE, *usize, *usize) callconv(.winapi) i32;
    extern "kernel32" fn SetProcessWorkingSetSize(std.os.windows.HANDLE, usize, usize) callconv(.winapi) i32;
};

test "protected buffer permits sensitive writes only after native protection" {
    var buffer = try Buffer.init(64);
    defer buffer.deinit();
    try std.testing.expect(buffer.report().locked);
    @memcpy((try buffer.writable())[0..6], "secret");
    try buffer.freeze();
    try std.testing.expect(buffer.report().read_only);
    try std.testing.expectEqualStrings("secret", buffer.bytes()[0..6]);
    (try buffer.writable())[0] = 'S';
    try std.testing.expect(!buffer.report().read_only);
}

/// Observer owns the release seam; checks bytes before any allocator poison.
pub const TestingBackend = struct {
    fail: enum { none, allocation, lock, dump, protection } = .none,
    locked: bool = false,
    dump_protected: bool = false,
    released: usize = 0,
    erased: bool = true,
    unlocks: usize = 0,
    writes_enabled: bool = false,

    pub fn backend(self: *TestingBackend) Backend {
        if (!builtin.is_test) @compileError("protected memory observer is test-only");
        return .{ .context = self, .allocate = allocate, .lock = lock, .dontDump = dump, .protect = protect, .unlock = unlock, .release = release };
    }
    fn from(context: *anyopaque) *TestingBackend {
        return @ptrCast(@alignCast(context));
    }
    fn allocate(context: *anyopaque, length: usize) Error!Page {
        const self = from(context);
        if (self.fail == .allocation) return error.OutOfMemory;
        const storage = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), length);
        @memset(storage, 0x5a);
        return storage;
    }
    fn lock(context: *anyopaque, _: Page) Error!void {
        const self = from(context);
        if (self.fail == .lock) return error.MemoryLockFailed;
        self.locked = true;
    }
    fn dump(context: *anyopaque, _: Page) Error!void {
        const self = from(context);
        if (self.fail == .dump) return error.DontDumpFailed;
        self.dump_protected = true;
    }
    fn protect(context: *anyopaque, _: Page, read_only: bool) Error!void {
        const self = from(context);
        if (self.fail == .protection) return error.MemoryProtectionFailed;
        std.debug.assert(self.locked and self.dump_protected);
        self.writes_enabled = !read_only;
    }
    fn unlock(context: *anyopaque, storage: Page) void {
        const self = from(context);
        self.erased = self.erased and std.mem.allEqual(u8, storage, 0);
        self.unlocks += 1;
        self.locked = false;
    }
    fn release(context: *anyopaque, storage: Page) void {
        const self = from(context);
        self.erased = self.erased and std.mem.allEqual(u8, storage, 0);
        self.released += 1;
        std.heap.page_allocator.free(storage);
    }
};

test "protected buffer release erases full mapping before unlock and free" {
    var observer = TestingBackend{};
    var buffer = try Buffer.initForTesting(17, observer.backend());
    try std.testing.expect(observer.writes_enabled);
    @memset(try buffer.writable(), 0x73);
    try buffer.freeze();
    try std.testing.expect(!observer.writes_enabled);
    buffer.deinit();
    try std.testing.expect(observer.erased);
    try std.testing.expectEqual(@as(usize, 1), observer.released);
    try std.testing.expectEqual(@as(usize, 1), observer.unlocks);
    buffer.deinit();
    try std.testing.expectEqual(@as(usize, 1), observer.released);
}

test "protected buffer rejects allocation locking dump and access failures without leaks" {
    const failures = [_]TestingBackend{ .{ .fail = .allocation }, .{ .fail = .lock }, .{ .fail = .dump }, .{ .fail = .protection } };
    const errors = [_]Error{ error.OutOfMemory, error.MemoryLockFailed, error.DontDumpFailed, error.MemoryProtectionFailed };
    for (failures, errors) |value, expected| {
        var observer = value;
        try std.testing.expectError(expected, Buffer.initForTesting(19 * 1024 * 1024, observer.backend()));
        try std.testing.expect(observer.erased);
        try std.testing.expectEqual(@as(usize, if (observer.fail == .allocation) 0 else 1), observer.released);
        try std.testing.expectEqual(@as(usize, if (observer.fail == .dump or observer.fail == .protection) 1 else 0), observer.unlocks);
    }
}

test "protected buffer cleans up cancellation and failed access transitions" {
    var observer = TestingBackend{};
    const Operation = struct {
        fn run(backend: Backend) !void {
            var buffer = try Buffer.initForTesting(100, backend);
            defer buffer.deinit();
            @memset(try buffer.writable(), 0x91);
            try buffer.freeze();
            return error.Canceled;
        }
    };
    try std.testing.expectError(error.Canceled, Operation.run(observer.backend()));
    try std.testing.expect(observer.erased);
    var buffer = try Buffer.initForTesting(100, observer.backend());
    defer buffer.deinit();
    try buffer.freeze();
    observer.fail = .protection;
    try std.testing.expectError(error.MemoryProtectionFailed, buffer.writable());
    try std.testing.expect(buffer.report().read_only);
    observer.fail = .none;
}
