const builtin = @import("builtin");
const arch = builtin.cpu.arch;
const common = @import("./common.zig");
const floatToInt = @import("./float_to_int.zig").floatToInt;

pub const panic = common.panic;

comptime {
    const fixtfti_fn = if (builtin.os.tag == .windows and arch == .x86_64) b: {
        // The "ti" functions must use Vector(2, u64) return types to adhere to the ABI
        // that LLVM expects compiler-rt to have.
        break :b __fixtfti_windows_x86_64;
    } else __fixtfti;

    @export(fixtfti_fn, .{ .name = "__fixtfti", .linkage = common.linkage });
}

pub fn __fixtfti(a: f128) callconv(.C) i128 {
    return floatToInt(i128, a);
}

const v128 = @import("std").meta.Vector(2, u64);

fn __fixtfti_windows_x86_64(a: f128) callconv(.C) v128 {
    return @bitCast(v128, floatToInt(i128, a));
}
