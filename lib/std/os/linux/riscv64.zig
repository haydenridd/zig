const builtin = @import("builtin");
const std = @import("../../std.zig");
const iovec = std.posix.iovec;
const iovec_const = std.posix.iovec_const;
const linux = std.os.linux;
const SYS = linux.SYS;
const uid_t = std.os.linux.uid_t;
const gid_t = std.os.linux.gid_t;
const pid_t = std.os.linux.pid_t;
const stack_t = linux.stack_t;
const sigset_t = linux.sigset_t;
const sockaddr = linux.sockaddr;
const socklen_t = linux.socklen_t;
const timespec = std.os.linux.timespec;

pub fn syscall0(number: SYS) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
        : "memory"
    );
}

pub fn syscall1(number: SYS, arg1: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
        : "memory"
    );
}

pub fn syscall2(number: SYS, arg1: usize, arg2: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
        : "memory"
    );
}

pub fn syscall3(number: SYS, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
        : "memory"
    );
}

pub fn syscall4(number: SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
        : "memory"
    );
}

pub fn syscall5(number: SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
          [arg5] "{x14}" (arg5),
        : "memory"
    );
}

pub fn syscall6(
    number: SYS,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
    arg6: usize,
) usize {
    return asm volatile ("ecall"
        : [ret] "={x10}" (-> usize),
        : [number] "{x17}" (@intFromEnum(number)),
          [arg1] "{x10}" (arg1),
          [arg2] "{x11}" (arg2),
          [arg3] "{x12}" (arg3),
          [arg4] "{x13}" (arg4),
          [arg5] "{x14}" (arg5),
          [arg6] "{x15}" (arg6),
        : "memory"
    );
}

pub fn clone() callconv(.naked) usize {
    // __clone(func, stack, flags, arg, ptid, tls, ctid)
    //         a0,   a1,    a2,    a3,  a4,   a5,  a6
    //
    // syscall(SYS_clone, flags, stack, ptid, tls, ctid)
    //         a7         a0,    a1,    a2,   a3,  a4
    asm volatile (
        \\    # Save func and arg to stack
        \\    addi a1, a1, -16
        \\    sd a0, 0(a1)
        \\    sd a3, 8(a1)
        \\
        \\    # Call SYS_clone
        \\    mv a0, a2
        \\    mv a2, a4
        \\    mv a3, a5
        \\    mv a4, a6
        \\    li a7, 220 # SYS_clone
        \\    ecall
        \\
        \\    beqz a0, 1f
        \\    # Parent
        \\    ret
        \\
        \\    # Child
        \\1:
    );
    if (builtin.unwind_tables != .none or !builtin.strip_debug_info) asm volatile (
        \\    .cfi_undefined ra
    );
    asm volatile (
        \\    mv fp, zero
        \\    mv ra, zero
        \\
        \\    ld a1, 0(sp)
        \\    ld a0, 8(sp)
        \\    jalr a1
        \\
        \\    # Exit
        \\    li a7, 93 # SYS_exit
        \\    ecall
    );
}

pub const restore = restore_rt;

pub fn restore_rt() callconv(.naked) noreturn {
    asm volatile (
        \\ ecall
        :
        : [number] "{x17}" (@intFromEnum(SYS.rt_sigreturn)),
        : "memory"
    );
}

pub const F = struct {
    pub const DUPFD = 0;
    pub const GETFD = 1;
    pub const SETFD = 2;
    pub const GETFL = 3;
    pub const SETFL = 4;
    pub const GETLK = 5;
    pub const SETLK = 6;
    pub const SETLKW = 7;
    pub const SETOWN = 8;
    pub const GETOWN = 9;
    pub const SETSIG = 10;
    pub const GETSIG = 11;

    pub const RDLCK = 0;
    pub const WRLCK = 1;
    pub const UNLCK = 2;

    pub const SETOWN_EX = 15;
    pub const GETOWN_EX = 16;

    pub const GETOWNER_UIDS = 17;
};

pub const blksize_t = i32;
pub const nlink_t = u32;
pub const time_t = i64;
pub const mode_t = u32;
pub const off_t = i64;
pub const ino_t = u64;
pub const dev_t = u64;
pub const blkcnt_t = i64;

pub const timeval = extern struct {
    sec: time_t,
    usec: i64,
};

pub const Flock = extern struct {
    type: i16,
    whence: i16,
    start: off_t,
    len: off_t,
    pid: pid_t,
    __unused: [4]u8,
};

// The `stat` definition used by the Linux kernel.
pub const Stat = extern struct {
    dev: dev_t,
    ino: ino_t,
    mode: mode_t,
    nlink: nlink_t,
    uid: uid_t,
    gid: gid_t,
    rdev: dev_t,
    __pad: usize,
    size: off_t,
    blksize: blksize_t,
    __pad2: i32,
    blocks: blkcnt_t,
    atim: timespec,
    mtim: timespec,
    ctim: timespec,
    __unused: [2]u32,

    pub fn atime(self: @This()) timespec {
        return self.atim;
    }

    pub fn mtime(self: @This()) timespec {
        return self.mtim;
    }

    pub fn ctime(self: @This()) timespec {
        return self.ctim;
    }
};

pub const Elf_Symndx = u32;

pub const VDSO = struct {
    pub const CGT_SYM = "__vdso_clock_gettime";
    pub const CGT_VER = "LINUX_4.15";
};

pub const f_ext_state = extern struct {
    f: [32]f32,
    fcsr: u32,
};

pub const d_ext_state = extern struct {
    f: [32]f64,
    fcsr: u32,
};

pub const q_ext_state = extern struct {
    f: [32]f128,
    fcsr: u32,
    _reserved: [3]u32,
};

pub const fpstate = extern union {
    f: f_ext_state,
    d: d_ext_state,
    q: q_ext_state,
};

pub const mcontext_t = extern struct {
    gregs: [32]u64,
    fpregs: fpstate,
};

pub const ucontext_t = extern struct {
    flags: c_ulong,
    link: ?*ucontext_t,
    stack: stack_t,
    sigmask: [1024 / @bitSizeOf(c_ulong)]c_ulong, // Currently a libc-compatible (1024-bit) sigmask
    mcontext: mcontext_t,
};

/// TODO
pub const getcontext = {};
