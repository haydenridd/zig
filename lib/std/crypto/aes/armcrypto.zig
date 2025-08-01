const std = @import("../../std.zig");
const mem = std.mem;
const debug = std.debug;

/// A single AES block.
pub const Block = struct {
    const Repr = @Vector(2, u64);

    pub const block_length: usize = 16;

    /// Internal representation of a block.
    repr: Repr,

    /// Convert a byte sequence into an internal representation.
    pub fn fromBytes(bytes: *const [16]u8) Block {
        const repr = mem.bytesToValue(Repr, bytes);
        return Block{ .repr = repr };
    }

    /// Convert the internal representation of a block into a byte sequence.
    pub fn toBytes(block: Block) [16]u8 {
        return mem.toBytes(block.repr);
    }

    /// XOR the block with a byte sequence.
    pub fn xorBytes(block: Block, bytes: *const [16]u8) [16]u8 {
        const x = block.repr ^ fromBytes(bytes).repr;
        return mem.toBytes(x);
    }

    const zero = @Vector(2, u64){ 0, 0 };

    /// Encrypt a block with a round key.
    pub fn encrypt(block: Block, round_key: Block) Block {
        return Block{
            .repr = (asm (
                \\ mov   %[out].16b, %[in].16b
                \\ aese  %[out].16b, %[zero].16b
                \\ aesmc %[out].16b, %[out].16b
                : [out] "=&x" (-> Repr),
                : [in] "x" (block.repr),
                  [zero] "x" (zero),
            )) ^ round_key.repr,
        };
    }

    /// Encrypt a block with the last round key.
    pub fn encryptLast(block: Block, round_key: Block) Block {
        return Block{
            .repr = (asm (
                \\ mov   %[out].16b, %[in].16b
                \\ aese  %[out].16b, %[zero].16b
                : [out] "=&x" (-> Repr),
                : [in] "x" (block.repr),
                  [zero] "x" (zero),
            )) ^ round_key.repr,
        };
    }

    /// Decrypt a block with a round key.
    pub fn decrypt(block: Block, inv_round_key: Block) Block {
        return Block{
            .repr = (asm (
                \\ mov   %[out].16b, %[in].16b
                \\ aesd  %[out].16b, %[zero].16b
                \\ aesimc %[out].16b, %[out].16b
                : [out] "=&x" (-> Repr),
                : [in] "x" (block.repr),
                  [zero] "x" (zero),
            )) ^ inv_round_key.repr,
        };
    }

    /// Decrypt a block with the last round key.
    pub fn decryptLast(block: Block, inv_round_key: Block) Block {
        return Block{
            .repr = (asm (
                \\ mov   %[out].16b, %[in].16b
                \\ aesd  %[out].16b, %[zero].16b
                : [out] "=&x" (-> Repr),
                : [in] "x" (block.repr),
                  [zero] "x" (zero),
            )) ^ inv_round_key.repr,
        };
    }

    /// Apply the bitwise XOR operation to the content of two blocks.
    pub fn xorBlocks(block1: Block, block2: Block) Block {
        return Block{ .repr = block1.repr ^ block2.repr };
    }

    /// Apply the bitwise AND operation to the content of two blocks.
    pub fn andBlocks(block1: Block, block2: Block) Block {
        return Block{ .repr = block1.repr & block2.repr };
    }

    /// Apply the bitwise OR operation to the content of two blocks.
    pub fn orBlocks(block1: Block, block2: Block) Block {
        return Block{ .repr = block1.repr | block2.repr };
    }

    /// Perform operations on multiple blocks in parallel.
    pub const parallel = struct {
        /// The recommended number of AES encryption/decryption to perform in parallel for the chosen implementation.
        pub const optimal_parallel_blocks = 6;

        /// Encrypt multiple blocks in parallel, each their own round key.
        pub fn encryptParallel(comptime count: usize, blocks: [count]Block, round_keys: [count]Block) [count]Block {
            comptime var i = 0;
            var out: [count]Block = undefined;
            inline while (i < count) : (i += 1) {
                out[i] = blocks[i].encrypt(round_keys[i]);
            }
            return out;
        }

        /// Decrypt multiple blocks in parallel, each their own round key.
        pub fn decryptParallel(comptime count: usize, blocks: [count]Block, round_keys: [count]Block) [count]Block {
            comptime var i = 0;
            var out: [count]Block = undefined;
            inline while (i < count) : (i += 1) {
                out[i] = blocks[i].decrypt(round_keys[i]);
            }
            return out;
        }

        /// Encrypt multiple blocks in parallel with the same round key.
        pub fn encryptWide(comptime count: usize, blocks: [count]Block, round_key: Block) [count]Block {
            comptime var i = 0;
            var out: [count]Block = undefined;
            inline while (i < count) : (i += 1) {
                out[i] = blocks[i].encrypt(round_key);
            }
            return out;
        }

        /// Decrypt multiple blocks in parallel with the same round key.
        pub fn decryptWide(comptime count: usize, blocks: [count]Block, round_key: Block) [count]Block {
            comptime var i = 0;
            var out: [count]Block = undefined;
            inline while (i < count) : (i += 1) {
                out[i] = blocks[i].decrypt(round_key);
            }
            return out;
        }

        /// Encrypt multiple blocks in parallel with the same last round key.
        pub fn encryptLastWide(comptime count: usize, blocks: [count]Block, round_key: Block) [count]Block {
            comptime var i = 0;
            var out: [count]Block = undefined;
            inline while (i < count) : (i += 1) {
                out[i] = blocks[i].encryptLast(round_key);
            }
            return out;
        }

        /// Decrypt multiple blocks in parallel with the same last round key.
        pub fn decryptLastWide(comptime count: usize, blocks: [count]Block, round_key: Block) [count]Block {
            comptime var i = 0;
            var out: [count]Block = undefined;
            inline while (i < count) : (i += 1) {
                out[i] = blocks[i].decryptLast(round_key);
            }
            return out;
        }
    };
};

/// A fixed-size vector of AES blocks.
/// All operations are performed in parallel, using SIMD instructions when available.
pub fn BlockVec(comptime blocks_count: comptime_int) type {
    return struct {
        const Self = @This();

        /// The number of AES blocks the target architecture can process with a single instruction.
        pub const native_vector_size = 1;

        /// The size of the AES block vector that the target architecture can process with a single instruction, in bytes.
        pub const native_word_size = native_vector_size * 16;

        const native_words = blocks_count;

        /// Internal representation of a block vector.
        repr: [native_words]Block,

        /// Length of the block vector in bytes.
        pub const block_length: usize = blocks_count * 16;

        /// Convert a byte sequence into an internal representation.
        pub fn fromBytes(bytes: *const [blocks_count * 16]u8) Self {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = Block.fromBytes(bytes[i * native_word_size ..][0..native_word_size]);
            }
            return out;
        }

        /// Convert the internal representation of a block vector into a byte sequence.
        pub fn toBytes(block_vec: Self) [blocks_count * 16]u8 {
            var out: [blocks_count * 16]u8 = undefined;
            inline for (0..native_words) |i| {
                out[i * native_word_size ..][0..native_word_size].* = block_vec.repr[i].toBytes();
            }
            return out;
        }

        /// XOR the block vector with a byte sequence.
        pub fn xorBytes(block_vec: Self, bytes: *const [blocks_count * 16]u8) [32]u8 {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = block_vec.repr[i].xorBytes(bytes[i * native_word_size ..][0..native_word_size]);
            }
            return out;
        }

        /// Apply the forward AES operation to the block vector with a vector of round keys.
        pub fn encrypt(block_vec: Self, round_key_vec: Self) Self {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = block_vec.repr[i].encrypt(round_key_vec.repr[i]);
            }
            return out;
        }

        /// Apply the forward AES operation to the block vector with a vector of last round keys.
        pub fn encryptLast(block_vec: Self, round_key_vec: Self) Self {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = block_vec.repr[i].encryptLast(round_key_vec.repr[i]);
            }
            return out;
        }

        /// Apply the inverse AES operation to the block vector with a vector of round keys.
        pub fn decrypt(block_vec: Self, inv_round_key_vec: Self) Self {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = block_vec.repr[i].decrypt(inv_round_key_vec.repr[i]);
            }
            return out;
        }

        /// Apply the inverse AES operation to the block vector with a vector of last round keys.
        pub fn decryptLast(block_vec: Self, inv_round_key_vec: Self) Self {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = block_vec.repr[i].decryptLast(inv_round_key_vec.repr[i]);
            }
            return out;
        }

        /// Apply the bitwise XOR operation to the content of two block vectors.
        pub fn xorBlocks(block_vec1: Self, block_vec2: Self) Self {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = block_vec1.repr[i].xorBlocks(block_vec2.repr[i]);
            }
            return out;
        }

        /// Apply the bitwise AND operation to the content of two block vectors.
        pub fn andBlocks(block_vec1: Self, block_vec2: Self) Self {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = block_vec1.repr[i].andBlocks(block_vec2.repr[i]);
            }
            return out;
        }

        /// Apply the bitwise OR operation to the content of two block vectors.
        pub fn orBlocks(block_vec1: Self, block_vec2: Block) Self {
            var out: Self = undefined;
            inline for (0..native_words) |i| {
                out.repr[i] = block_vec1.repr[i].orBlocks(block_vec2.repr[i]);
            }
            return out;
        }
    };
}

fn KeySchedule(comptime Aes: type) type {
    std.debug.assert(Aes.rounds == 10 or Aes.rounds == 14);
    const rounds = Aes.rounds;

    return struct {
        const Self = @This();

        const Repr = Aes.block.Repr;

        const zero = @Vector(2, u64){ 0, 0 };
        const mask1 = @Vector(16, u8){ 13, 14, 15, 12, 13, 14, 15, 12, 13, 14, 15, 12, 13, 14, 15, 12 };
        const mask2 = @Vector(16, u8){ 12, 13, 14, 15, 12, 13, 14, 15, 12, 13, 14, 15, 12, 13, 14, 15 };

        round_keys: [rounds + 1]Block,

        fn drc128(comptime rc: u8, t: Repr) Repr {
            var v1: Repr = undefined;
            var v2: Repr = undefined;
            var v3: Repr = undefined;
            var v4: Repr = undefined;

            return asm (
                \\ movi %[v2].4s, %[rc]
                \\ tbl  %[v4].16b, {%[t].16b}, %[mask].16b
                \\ ext  %[r].16b, %[zero].16b, %[t].16b, #12
                \\ aese %[v4].16b, %[zero].16b
                \\ eor  %[v2].16b, %[r].16b, %[v2].16b
                \\ ext  %[r].16b, %[zero].16b, %[r].16b, #12
                \\ eor  %[v1].16b, %[v2].16b, %[t].16b
                \\ ext  %[v3].16b, %[zero].16b, %[r].16b, #12
                \\ eor  %[v1].16b, %[v1].16b, %[r].16b
                \\ eor  %[r].16b, %[v1].16b, %[v3].16b
                \\ eor  %[r].16b, %[r].16b, %[v4].16b
                : [r] "=&x" (-> Repr),
                  [v1] "=&x" (v1),
                  [v2] "=&x" (v2),
                  [v3] "=&x" (v3),
                  [v4] "=&x" (v4),
                : [rc] "N" (rc),
                  [t] "x" (t),
                  [zero] "x" (zero),
                  [mask] "x" (mask1),
            );
        }

        fn drc256(comptime second: bool, comptime rc: u8, t: Repr, tx: Repr) Repr {
            var v1: Repr = undefined;
            var v2: Repr = undefined;
            var v3: Repr = undefined;
            var v4: Repr = undefined;

            return asm (
                \\ movi %[v2].4s, %[rc]
                \\ tbl  %[v4].16b, {%[t].16b}, %[mask].16b
                \\ ext  %[r].16b, %[zero].16b, %[tx].16b, #12
                \\ aese %[v4].16b, %[zero].16b
                \\ eor  %[v1].16b, %[tx].16b, %[r].16b
                \\ ext  %[r].16b, %[zero].16b, %[r].16b, #12
                \\ eor  %[v1].16b, %[v1].16b, %[r].16b
                \\ ext  %[v3].16b, %[zero].16b, %[r].16b, #12
                \\ eor  %[v1].16b, %[v1].16b, %[v2].16b
                \\ eor  %[v1].16b, %[v1].16b, %[v3].16b
                \\ eor  %[r].16b, %[v1].16b, %[v4].16b
                : [r] "=&x" (-> Repr),
                  [v1] "=&x" (v1),
                  [v2] "=&x" (v2),
                  [v3] "=&x" (v3),
                  [v4] "=&x" (v4),
                : [rc] "N" (if (second) @as(u8, 0) else rc),
                  [t] "x" (t),
                  [tx] "x" (tx),
                  [zero] "x" (zero),
                  [mask] "x" (if (second) mask2 else mask1),
            );
        }

        fn expand128(t1: *Block) Self {
            var round_keys: [11]Block = undefined;
            const rcs = [_]u8{ 1, 2, 4, 8, 16, 32, 64, 128, 27, 54 };
            inline for (rcs, 0..) |rc, round| {
                round_keys[round] = t1.*;
                t1.repr = drc128(rc, t1.repr);
            }
            round_keys[rcs.len] = t1.*;
            return Self{ .round_keys = round_keys };
        }

        fn expand256(t1: *Block, t2: *Block) Self {
            var round_keys: [15]Block = undefined;
            const rcs = [_]u8{ 1, 2, 4, 8, 16, 32 };
            round_keys[0] = t1.*;
            inline for (rcs, 0..) |rc, round| {
                round_keys[round * 2 + 1] = t2.*;
                t1.repr = drc256(false, rc, t2.repr, t1.repr);
                round_keys[round * 2 + 2] = t1.*;
                t2.repr = drc256(true, rc, t1.repr, t2.repr);
            }
            round_keys[rcs.len * 2 + 1] = t2.*;
            t1.repr = drc256(false, 64, t2.repr, t1.repr);
            round_keys[rcs.len * 2 + 2] = t1.*;
            return Self{ .round_keys = round_keys };
        }

        /// Invert the key schedule.
        pub fn invert(key_schedule: Self) Self {
            const round_keys = &key_schedule.round_keys;
            var inv_round_keys: [rounds + 1]Block = undefined;
            inv_round_keys[0] = round_keys[rounds];
            comptime var i = 1;
            inline while (i < rounds) : (i += 1) {
                inv_round_keys[i] = Block{
                    .repr = asm (
                        \\ aesimc %[inv_rk].16b, %[rk].16b
                        : [inv_rk] "=x" (-> Repr),
                        : [rk] "x" (round_keys[rounds - i].repr),
                    ),
                };
            }
            inv_round_keys[rounds] = round_keys[0];
            return Self{ .round_keys = inv_round_keys };
        }
    };
}

/// A context to perform encryption using the standard AES key schedule.
pub fn AesEncryptCtx(comptime Aes: type) type {
    std.debug.assert(Aes.key_bits == 128 or Aes.key_bits == 256);
    const rounds = Aes.rounds;

    return struct {
        const Self = @This();
        pub const block = Aes.block;
        pub const block_length = block.block_length;
        key_schedule: KeySchedule(Aes),

        /// Create a new encryption context with the given key.
        pub fn init(key: [Aes.key_bits / 8]u8) Self {
            var t1 = Block.fromBytes(key[0..16]);
            const key_schedule = if (Aes.key_bits == 128) ks: {
                break :ks KeySchedule(Aes).expand128(&t1);
            } else ks: {
                var t2 = Block.fromBytes(key[16..32]);
                break :ks KeySchedule(Aes).expand256(&t1, &t2);
            };
            return Self{
                .key_schedule = key_schedule,
            };
        }

        /// Encrypt a single block.
        pub fn encrypt(ctx: Self, dst: *[16]u8, src: *const [16]u8) void {
            const round_keys = ctx.key_schedule.round_keys;
            var t = Block.fromBytes(src).xorBlocks(round_keys[0]);
            comptime var i = 1;
            inline while (i < rounds) : (i += 1) {
                t = t.encrypt(round_keys[i]);
            }
            t = t.encryptLast(round_keys[rounds]);
            dst.* = t.toBytes();
        }

        /// Encrypt+XOR a single block.
        pub fn xor(ctx: Self, dst: *[16]u8, src: *const [16]u8, counter: [16]u8) void {
            const round_keys = ctx.key_schedule.round_keys;
            var t = Block.fromBytes(&counter).xorBlocks(round_keys[0]);
            comptime var i = 1;
            inline while (i < rounds) : (i += 1) {
                t = t.encrypt(round_keys[i]);
            }
            t = t.encryptLast(round_keys[rounds]);
            dst.* = t.xorBytes(src);
        }

        /// Encrypt multiple blocks, possibly leveraging parallelization.
        pub fn encryptWide(ctx: Self, comptime count: usize, dst: *[16 * count]u8, src: *const [16 * count]u8) void {
            const round_keys = ctx.key_schedule.round_keys;
            var ts: [count]Block = undefined;
            comptime var j = 0;
            inline while (j < count) : (j += 1) {
                ts[j] = Block.fromBytes(src[j * 16 .. j * 16 + 16][0..16]).xorBlocks(round_keys[0]);
            }
            comptime var i = 1;
            inline while (i < rounds) : (i += 1) {
                ts = Block.parallel.encryptWide(count, ts, round_keys[i]);
            }
            ts = Block.parallel.encryptLastWide(count, ts, round_keys[i]);
            j = 0;
            inline while (j < count) : (j += 1) {
                dst[16 * j .. 16 * j + 16].* = ts[j].toBytes();
            }
        }

        /// Encrypt+XOR multiple blocks, possibly leveraging parallelization.
        pub fn xorWide(ctx: Self, comptime count: usize, dst: *[16 * count]u8, src: *const [16 * count]u8, counters: [16 * count]u8) void {
            const round_keys = ctx.key_schedule.round_keys;
            var ts: [count]Block = undefined;
            comptime var j = 0;
            inline while (j < count) : (j += 1) {
                ts[j] = Block.fromBytes(counters[j * 16 .. j * 16 + 16][0..16]).xorBlocks(round_keys[0]);
            }
            comptime var i = 1;
            inline while (i < rounds) : (i += 1) {
                ts = Block.parallel.encryptWide(count, ts, round_keys[i]);
            }
            ts = Block.parallel.encryptLastWide(count, ts, round_keys[i]);
            j = 0;
            inline while (j < count) : (j += 1) {
                dst[16 * j .. 16 * j + 16].* = ts[j].xorBytes(src[16 * j .. 16 * j + 16]);
            }
        }
    };
}

/// A context to perform decryption using the standard AES key schedule.
pub fn AesDecryptCtx(comptime Aes: type) type {
    std.debug.assert(Aes.key_bits == 128 or Aes.key_bits == 256);
    const rounds = Aes.rounds;

    return struct {
        const Self = @This();
        pub const block = Aes.block;
        pub const block_length = block.block_length;
        key_schedule: KeySchedule(Aes),

        /// Create a decryption context from an existing encryption context.
        pub fn initFromEnc(ctx: AesEncryptCtx(Aes)) Self {
            return Self{
                .key_schedule = ctx.key_schedule.invert(),
            };
        }

        /// Create a new decryption context with the given key.
        pub fn init(key: [Aes.key_bits / 8]u8) Self {
            const enc_ctx = AesEncryptCtx(Aes).init(key);
            return initFromEnc(enc_ctx);
        }

        /// Decrypt a single block.
        pub fn decrypt(ctx: Self, dst: *[16]u8, src: *const [16]u8) void {
            const inv_round_keys = ctx.key_schedule.round_keys;
            var t = Block.fromBytes(src).xorBlocks(inv_round_keys[0]);
            comptime var i = 1;
            inline while (i < rounds) : (i += 1) {
                t = t.decrypt(inv_round_keys[i]);
            }
            t = t.decryptLast(inv_round_keys[rounds]);
            dst.* = t.toBytes();
        }

        /// Decrypt multiple blocks, possibly leveraging parallelization.
        pub fn decryptWide(ctx: Self, comptime count: usize, dst: *[16 * count]u8, src: *const [16 * count]u8) void {
            const inv_round_keys = ctx.key_schedule.round_keys;
            var ts: [count]Block = undefined;
            comptime var j = 0;
            inline while (j < count) : (j += 1) {
                ts[j] = Block.fromBytes(src[j * 16 .. j * 16 + 16][0..16]).xorBlocks(inv_round_keys[0]);
            }
            comptime var i = 1;
            inline while (i < rounds) : (i += 1) {
                ts = Block.parallel.decryptWide(count, ts, inv_round_keys[i]);
            }
            ts = Block.parallel.decryptLastWide(count, ts, inv_round_keys[i]);
            j = 0;
            inline while (j < count) : (j += 1) {
                dst[16 * j .. 16 * j + 16].* = ts[j].toBytes();
            }
        }
    };
}

/// AES-128 with the standard key schedule.
pub const Aes128 = struct {
    pub const key_bits: usize = 128;
    pub const rounds = ((key_bits - 64) / 32 + 8);
    pub const block = Block;

    /// Create a new context for encryption.
    pub fn initEnc(key: [key_bits / 8]u8) AesEncryptCtx(Aes128) {
        return AesEncryptCtx(Aes128).init(key);
    }

    /// Create a new context for decryption.
    pub fn initDec(key: [key_bits / 8]u8) AesDecryptCtx(Aes128) {
        return AesDecryptCtx(Aes128).init(key);
    }
};

/// AES-256 with the standard key schedule.
pub const Aes256 = struct {
    pub const key_bits: usize = 256;
    pub const rounds = ((key_bits - 64) / 32 + 8);
    pub const block = Block;

    /// Create a new context for encryption.
    pub fn initEnc(key: [key_bits / 8]u8) AesEncryptCtx(Aes256) {
        return AesEncryptCtx(Aes256).init(key);
    }

    /// Create a new context for decryption.
    pub fn initDec(key: [key_bits / 8]u8) AesDecryptCtx(Aes256) {
        return AesDecryptCtx(Aes256).init(key);
    }
};
