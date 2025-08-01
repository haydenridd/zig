//! Represents in-progress parsing, will be converted to an Ast after completion.

pub const Error = error{ParseError} || Allocator.Error;

gpa: Allocator,
source: []const u8,
tokens: Ast.TokenList.Slice,
tok_i: TokenIndex,
errors: std.ArrayListUnmanaged(AstError),
nodes: Ast.NodeList,
extra_data: std.ArrayListUnmanaged(u32),
scratch: std.ArrayListUnmanaged(Node.Index),

fn tokenTag(p: *const Parse, token_index: TokenIndex) Token.Tag {
    return p.tokens.items(.tag)[token_index];
}

fn tokenStart(p: *const Parse, token_index: TokenIndex) Ast.ByteOffset {
    return p.tokens.items(.start)[token_index];
}

fn nodeTag(p: *const Parse, node: Node.Index) Node.Tag {
    return p.nodes.items(.tag)[@intFromEnum(node)];
}

fn nodeMainToken(p: *const Parse, node: Node.Index) TokenIndex {
    return p.nodes.items(.main_token)[@intFromEnum(node)];
}

fn nodeData(p: *const Parse, node: Node.Index) Node.Data {
    return p.nodes.items(.data)[@intFromEnum(node)];
}

const SmallSpan = union(enum) {
    zero_or_one: Node.OptionalIndex,
    multi: Node.SubRange,
};

const Members = struct {
    len: usize,
    /// Must be either `.opt_node_and_opt_node` if `len <= 2` or `.extra_range` otherwise.
    data: Node.Data,
    trailing: bool,

    fn toSpan(self: Members, p: *Parse) !Node.SubRange {
        return switch (self.len) {
            0 => p.listToSpan(&.{}),
            1 => p.listToSpan(&.{self.data.opt_node_and_opt_node[0].unwrap().?}),
            2 => p.listToSpan(&.{ self.data.opt_node_and_opt_node[0].unwrap().?, self.data.opt_node_and_opt_node[1].unwrap().? }),
            else => self.data.extra_range,
        };
    }
};

fn listToSpan(p: *Parse, list: []const Node.Index) Allocator.Error!Node.SubRange {
    try p.extra_data.appendSlice(p.gpa, @ptrCast(list));
    return .{
        .start = @enumFromInt(p.extra_data.items.len - list.len),
        .end = @enumFromInt(p.extra_data.items.len),
    };
}

fn addNode(p: *Parse, elem: Ast.Node) Allocator.Error!Node.Index {
    const result: Node.Index = @enumFromInt(p.nodes.len);
    try p.nodes.append(p.gpa, elem);
    return result;
}

fn setNode(p: *Parse, i: usize, elem: Ast.Node) Node.Index {
    p.nodes.set(i, elem);
    return @enumFromInt(i);
}

fn reserveNode(p: *Parse, tag: Ast.Node.Tag) !usize {
    try p.nodes.resize(p.gpa, p.nodes.len + 1);
    p.nodes.items(.tag)[p.nodes.len - 1] = tag;
    return p.nodes.len - 1;
}

fn unreserveNode(p: *Parse, node_index: usize) void {
    if (p.nodes.len == node_index) {
        p.nodes.resize(p.gpa, p.nodes.len - 1) catch unreachable;
    } else {
        // There is zombie node left in the tree, let's make it as inoffensive as possible
        // (sadly there's no no-op node)
        p.nodes.items(.tag)[node_index] = .unreachable_literal;
        p.nodes.items(.main_token)[node_index] = p.tok_i;
    }
}

fn addExtra(p: *Parse, extra: anytype) Allocator.Error!ExtraIndex {
    const fields = std.meta.fields(@TypeOf(extra));
    try p.extra_data.ensureUnusedCapacity(p.gpa, fields.len);
    const result: ExtraIndex = @enumFromInt(p.extra_data.items.len);
    inline for (fields) |field| {
        const data: u32 = switch (field.type) {
            Node.Index,
            Node.OptionalIndex,
            OptionalTokenIndex,
            ExtraIndex,
            => @intFromEnum(@field(extra, field.name)),
            TokenIndex,
            => @field(extra, field.name),
            else => @compileError("unexpected field type"),
        };
        p.extra_data.appendAssumeCapacity(data);
    }
    return result;
}

fn warnExpected(p: *Parse, expected_token: Token.Tag) error{OutOfMemory}!void {
    @branchHint(.cold);
    try p.warnMsg(.{
        .tag = .expected_token,
        .token = p.tok_i,
        .extra = .{ .expected_tag = expected_token },
    });
}

fn warn(p: *Parse, error_tag: AstError.Tag) error{OutOfMemory}!void {
    @branchHint(.cold);
    try p.warnMsg(.{ .tag = error_tag, .token = p.tok_i });
}

fn warnMsg(p: *Parse, msg: Ast.Error) error{OutOfMemory}!void {
    @branchHint(.cold);
    switch (msg.tag) {
        .expected_semi_after_decl,
        .expected_semi_after_stmt,
        .expected_comma_after_field,
        .expected_comma_after_arg,
        .expected_comma_after_param,
        .expected_comma_after_initializer,
        .expected_comma_after_switch_prong,
        .expected_comma_after_for_operand,
        .expected_comma_after_capture,
        .expected_semi_or_else,
        .expected_semi_or_lbrace,
        .expected_token,
        .expected_block,
        .expected_block_or_assignment,
        .expected_block_or_expr,
        .expected_block_or_field,
        .expected_expr,
        .expected_expr_or_assignment,
        .expected_fn,
        .expected_inlinable,
        .expected_labelable,
        .expected_param_list,
        .expected_prefix_expr,
        .expected_primary_type_expr,
        .expected_pub_item,
        .expected_return_type,
        .expected_suffix_op,
        .expected_type_expr,
        .expected_var_decl,
        .expected_var_decl_or_fn,
        .expected_loop_payload,
        .expected_container,
        => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
            var copy = msg;
            copy.token_is_prev = true;
            copy.token -= 1;
            return p.errors.append(p.gpa, copy);
        },
        else => {},
    }
    try p.errors.append(p.gpa, msg);
}

fn fail(p: *Parse, tag: Ast.Error.Tag) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    return p.failMsg(.{ .tag = tag, .token = p.tok_i });
}

fn failExpected(p: *Parse, expected_token: Token.Tag) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    return p.failMsg(.{
        .tag = .expected_token,
        .token = p.tok_i,
        .extra = .{ .expected_tag = expected_token },
    });
}

fn failMsg(p: *Parse, msg: Ast.Error) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    try p.warnMsg(msg);
    return error.ParseError;
}

/// Root <- skip container_doc_comment? ContainerMembers eof
pub fn parseRoot(p: *Parse) !void {
    // Root node must be index 0.
    p.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });
    const root_members = try p.parseContainerMembers();
    const root_decls = try root_members.toSpan(p);
    if (p.tokenTag(p.tok_i) != .eof) {
        try p.warnExpected(.eof);
    }
    p.nodes.items(.data)[0] = .{ .extra_range = root_decls };
}

/// Parse in ZON mode. Subset of the language.
/// TODO: set a flag in Parse struct, and honor that flag
/// by emitting compilation errors when non-zon nodes are encountered.
pub fn parseZon(p: *Parse) !void {
    // We must use index 0 so that 0 can be used as null elsewhere.
    p.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });
    const node_index = p.expectExpr() catch |err| switch (err) {
        error.ParseError => {
            assert(p.errors.items.len > 0);
            return;
        },
        else => |e| return e,
    };
    if (p.tokenTag(p.tok_i) != .eof) {
        try p.warnExpected(.eof);
    }
    p.nodes.items(.data)[0] = .{ .node = node_index };
}

/// ContainerMembers <- ContainerDeclaration* (ContainerField COMMA)* (ContainerField / ContainerDeclaration*)
///
/// ContainerDeclaration <- TestDecl / ComptimeDecl / doc_comment? KEYWORD_pub? Decl
///
/// ComptimeDecl <- KEYWORD_comptime Block
fn parseContainerMembers(p: *Parse) Allocator.Error!Members {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    var field_state: union(enum) {
        /// No fields have been seen.
        none,
        /// Currently parsing fields.
        seen,
        /// Saw fields and then a declaration after them.
        /// Payload is first token of previous declaration.
        end: Node.Index,
        /// There was a declaration between fields, don't report more errors.
        err,
    } = .none;

    var last_field: TokenIndex = undefined;

    // Skip container doc comments.
    while (p.eatToken(.container_doc_comment)) |_| {}

    var trailing = false;
    while (true) {
        const doc_comment = try p.eatDocComments();

        switch (p.tokenTag(p.tok_i)) {
            .keyword_test => {
                if (doc_comment) |some| {
                    try p.warnMsg(.{ .tag = .test_doc_comment, .token = some });
                }
                const maybe_test_decl_node = try p.expectTestDeclRecoverable();
                if (maybe_test_decl_node) |test_decl_node| {
                    if (field_state == .seen) {
                        field_state = .{ .end = test_decl_node };
                    }
                    try p.scratch.append(p.gpa, test_decl_node);
                }
                trailing = false;
            },
            .keyword_comptime => switch (p.tokenTag(p.tok_i + 1)) {
                .l_brace => {
                    if (doc_comment) |some| {
                        try p.warnMsg(.{ .tag = .comptime_doc_comment, .token = some });
                    }
                    const comptime_token = p.nextToken();
                    const opt_block = p.parseBlock() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ParseError => blk: {
                            p.findNextContainerMember();
                            break :blk null;
                        },
                    };
                    if (opt_block) |block| {
                        const comptime_node = try p.addNode(.{
                            .tag = .@"comptime",
                            .main_token = comptime_token,
                            .data = .{ .node = block },
                        });
                        if (field_state == .seen) {
                            field_state = .{ .end = comptime_node };
                        }
                        try p.scratch.append(p.gpa, comptime_node);
                    }
                    trailing = false;
                },
                else => {
                    const identifier = p.tok_i;
                    defer last_field = identifier;
                    const container_field = p.expectContainerField() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ParseError => {
                            p.findNextContainerMember();
                            continue;
                        },
                    };
                    switch (field_state) {
                        .none => field_state = .seen,
                        .err, .seen => {},
                        .end => |node| {
                            try p.warnMsg(.{
                                .tag = .decl_between_fields,
                                .token = p.nodeMainToken(node),
                            });
                            try p.warnMsg(.{
                                .tag = .previous_field,
                                .is_note = true,
                                .token = last_field,
                            });
                            try p.warnMsg(.{
                                .tag = .next_field,
                                .is_note = true,
                                .token = identifier,
                            });
                            // Continue parsing; error will be reported later.
                            field_state = .err;
                        },
                    }
                    try p.scratch.append(p.gpa, container_field);
                    switch (p.tokenTag(p.tok_i)) {
                        .comma => {
                            p.tok_i += 1;
                            trailing = true;
                            continue;
                        },
                        .r_brace, .eof => {
                            trailing = false;
                            break;
                        },
                        else => {},
                    }
                    // There is not allowed to be a decl after a field with no comma.
                    // Report error but recover parser.
                    try p.warn(.expected_comma_after_field);
                    p.findNextContainerMember();
                },
            },
            .keyword_pub => {
                p.tok_i += 1;
                const opt_top_level_decl = try p.expectTopLevelDeclRecoverable();
                if (opt_top_level_decl) |top_level_decl| {
                    if (field_state == .seen) {
                        field_state = .{ .end = top_level_decl };
                    }
                    try p.scratch.append(p.gpa, top_level_decl);
                }
                trailing = p.tokenTag(p.tok_i - 1) == .semicolon;
            },
            .keyword_const,
            .keyword_var,
            .keyword_threadlocal,
            .keyword_export,
            .keyword_extern,
            .keyword_inline,
            .keyword_noinline,
            .keyword_fn,
            => {
                const opt_top_level_decl = try p.expectTopLevelDeclRecoverable();
                if (opt_top_level_decl) |top_level_decl| {
                    if (field_state == .seen) {
                        field_state = .{ .end = top_level_decl };
                    }
                    try p.scratch.append(p.gpa, top_level_decl);
                }
                trailing = p.tokenTag(p.tok_i - 1) == .semicolon;
            },
            .eof, .r_brace => {
                if (doc_comment) |tok| {
                    try p.warnMsg(.{
                        .tag = .unattached_doc_comment,
                        .token = tok,
                    });
                }
                break;
            },
            else => {
                const c_container = p.parseCStyleContainer() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ParseError => false,
                };
                if (c_container) continue;

                const identifier = p.tok_i;
                defer last_field = identifier;
                const container_field = p.expectContainerField() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ParseError => {
                        p.findNextContainerMember();
                        continue;
                    },
                };
                switch (field_state) {
                    .none => field_state = .seen,
                    .err, .seen => {},
                    .end => |node| {
                        try p.warnMsg(.{
                            .tag = .decl_between_fields,
                            .token = p.nodeMainToken(node),
                        });
                        try p.warnMsg(.{
                            .tag = .previous_field,
                            .is_note = true,
                            .token = last_field,
                        });
                        try p.warnMsg(.{
                            .tag = .next_field,
                            .is_note = true,
                            .token = identifier,
                        });
                        // Continue parsing; error will be reported later.
                        field_state = .err;
                    },
                }
                try p.scratch.append(p.gpa, container_field);
                switch (p.tokenTag(p.tok_i)) {
                    .comma => {
                        p.tok_i += 1;
                        trailing = true;
                        continue;
                    },
                    .r_brace, .eof => {
                        trailing = false;
                        break;
                    },
                    else => {},
                }
                // There is not allowed to be a decl after a field with no comma.
                // Report error but recover parser.
                try p.warn(.expected_comma_after_field);
                if (p.tokenTag(p.tok_i) == .semicolon and p.tokenTag(identifier) == .identifier) {
                    try p.warnMsg(.{
                        .tag = .var_const_decl,
                        .is_note = true,
                        .token = identifier,
                    });
                }
                p.findNextContainerMember();
                continue;
            },
        }
    }

    const items = p.scratch.items[scratch_top..];
    if (items.len <= 2) {
        return Members{
            .len = items.len,
            .data = .{ .opt_node_and_opt_node = .{
                if (items.len >= 1) items[0].toOptional() else .none,
                if (items.len >= 2) items[1].toOptional() else .none,
            } },
            .trailing = trailing,
        };
    } else {
        return Members{
            .len = items.len,
            .data = .{ .extra_range = try p.listToSpan(items) },
            .trailing = trailing,
        };
    }
}

/// Attempts to find next container member by searching for certain tokens
fn findNextContainerMember(p: *Parse) void {
    var level: u32 = 0;
    while (true) {
        const tok = p.nextToken();
        switch (p.tokenTag(tok)) {
            // Any of these can start a new top level declaration.
            .keyword_test,
            .keyword_comptime,
            .keyword_pub,
            .keyword_export,
            .keyword_extern,
            .keyword_inline,
            .keyword_noinline,
            .keyword_threadlocal,
            .keyword_const,
            .keyword_var,
            .keyword_fn,
            => {
                if (level == 0) {
                    p.tok_i -= 1;
                    return;
                }
            },
            .identifier => {
                if (p.tokenTag(tok + 1) == .comma and level == 0) {
                    p.tok_i -= 1;
                    return;
                }
            },
            .comma, .semicolon => {
                // this decl was likely meant to end here
                if (level == 0) {
                    return;
                }
            },
            .l_paren, .l_bracket, .l_brace => level += 1,
            .r_paren, .r_bracket => {
                if (level != 0) level -= 1;
            },
            .r_brace => {
                if (level == 0) {
                    // end of container, exit
                    p.tok_i -= 1;
                    return;
                }
                level -= 1;
            },
            .eof => {
                p.tok_i -= 1;
                return;
            },
            else => {},
        }
    }
}

/// Attempts to find the next statement by searching for a semicolon
fn findNextStmt(p: *Parse) void {
    var level: u32 = 0;
    while (true) {
        const tok = p.nextToken();
        switch (p.tokenTag(tok)) {
            .l_brace => level += 1,
            .r_brace => {
                if (level == 0) {
                    p.tok_i -= 1;
                    return;
                }
                level -= 1;
            },
            .semicolon => {
                if (level == 0) {
                    return;
                }
            },
            .eof => {
                p.tok_i -= 1;
                return;
            },
            else => {},
        }
    }
}

/// TestDecl <- KEYWORD_test (STRINGLITERALSINGLE / IDENTIFIER)? Block
fn expectTestDecl(p: *Parse) Error!Node.Index {
    const test_token = p.assertToken(.keyword_test);
    const name_token: OptionalTokenIndex = switch (p.tokenTag(p.tok_i)) {
        .string_literal, .identifier => .fromToken(p.nextToken()),
        else => .none,
    };
    const block_node = try p.parseBlock() orelse return p.fail(.expected_block);
    return p.addNode(.{
        .tag = .test_decl,
        .main_token = test_token,
        .data = .{ .opt_token_and_node = .{
            name_token,
            block_node,
        } },
    });
}

fn expectTestDeclRecoverable(p: *Parse) error{OutOfMemory}!?Node.Index {
    if (p.expectTestDecl()) |node| {
        return node;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {
            p.findNextContainerMember();
            return null;
        },
    }
}

/// Decl
///     <- (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE? / KEYWORD_inline / KEYWORD_noinline)? FnProto (SEMICOLON / Block)
///      / (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE?)? KEYWORD_threadlocal? VarDecl
fn expectTopLevelDecl(p: *Parse) !?Node.Index {
    const extern_export_inline_token = p.nextToken();
    var is_extern: bool = false;
    var expect_fn: bool = false;
    var expect_var_or_fn: bool = false;
    switch (p.tokenTag(extern_export_inline_token)) {
        .keyword_extern => {
            _ = p.eatToken(.string_literal);
            is_extern = true;
            expect_var_or_fn = true;
        },
        .keyword_export => expect_var_or_fn = true,
        .keyword_inline, .keyword_noinline => expect_fn = true,
        else => p.tok_i -= 1,
    }
    const opt_fn_proto = try p.parseFnProto();
    if (opt_fn_proto) |fn_proto| {
        switch (p.tokenTag(p.tok_i)) {
            .semicolon => {
                p.tok_i += 1;
                return fn_proto;
            },
            .l_brace => {
                if (is_extern) {
                    try p.warnMsg(.{ .tag = .extern_fn_body, .token = extern_export_inline_token });
                    return null;
                }
                const fn_decl_index = try p.reserveNode(.fn_decl);
                errdefer p.unreserveNode(fn_decl_index);

                const body_block = try p.parseBlock();
                return p.setNode(fn_decl_index, .{
                    .tag = .fn_decl,
                    .main_token = p.nodeMainToken(fn_proto),
                    .data = .{ .node_and_node = .{
                        fn_proto,
                        body_block.?,
                    } },
                });
            },
            else => {
                // Since parseBlock only return error.ParseError on
                // a missing '}' we can assume this function was
                // supposed to end here.
                try p.warn(.expected_semi_or_lbrace);
                return null;
            },
        }
    }
    if (expect_fn) {
        try p.warn(.expected_fn);
        return error.ParseError;
    }

    const thread_local_token = p.eatToken(.keyword_threadlocal);
    if (try p.parseGlobalVarDecl()) |var_decl| return var_decl;
    if (thread_local_token != null) {
        return p.fail(.expected_var_decl);
    }
    if (expect_var_or_fn) {
        return p.fail(.expected_var_decl_or_fn);
    }
    return p.fail(.expected_pub_item);
}

fn expectTopLevelDeclRecoverable(p: *Parse) error{OutOfMemory}!?Node.Index {
    return p.expectTopLevelDecl() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {
            p.findNextContainerMember();
            return null;
        },
    };
}

/// FnProto <- KEYWORD_fn IDENTIFIER? LPAREN ParamDeclList RPAREN ByteAlign? AddrSpace? LinkSection? CallConv? EXCLAMATIONMARK? TypeExpr
fn parseFnProto(p: *Parse) !?Node.Index {
    const fn_token = p.eatToken(.keyword_fn) orelse return null;

    // We want the fn proto node to be before its children in the array.
    const fn_proto_index = try p.reserveNode(.fn_proto);
    errdefer p.unreserveNode(fn_proto_index);

    _ = p.eatToken(.identifier);
    const params = try p.parseParamDeclList();
    const align_expr = try p.parseByteAlign();
    const addrspace_expr = try p.parseAddrSpace();
    const section_expr = try p.parseLinkSection();
    const callconv_expr = try p.parseCallconv();
    _ = p.eatToken(.bang);

    const return_type_expr = try p.parseTypeExpr();
    if (return_type_expr == null) {
        // most likely the user forgot to specify the return type.
        // Mark return type as invalid and try to continue.
        try p.warn(.expected_return_type);
    }

    if (align_expr == null and section_expr == null and callconv_expr == null and addrspace_expr == null) {
        switch (params) {
            .zero_or_one => |param| return p.setNode(fn_proto_index, .{
                .tag = .fn_proto_simple,
                .main_token = fn_token,
                .data = .{ .opt_node_and_opt_node = .{
                    param,
                    .fromOptional(return_type_expr),
                } },
            }),
            .multi => |span| {
                return p.setNode(fn_proto_index, .{
                    .tag = .fn_proto_multi,
                    .main_token = fn_token,
                    .data = .{ .extra_and_opt_node = .{
                        try p.addExtra(Node.SubRange{
                            .start = span.start,
                            .end = span.end,
                        }),
                        .fromOptional(return_type_expr),
                    } },
                });
            },
        }
    }
    switch (params) {
        .zero_or_one => |param| return p.setNode(fn_proto_index, .{
            .tag = .fn_proto_one,
            .main_token = fn_token,
            .data = .{ .extra_and_opt_node = .{
                try p.addExtra(Node.FnProtoOne{
                    .param = param,
                    .align_expr = .fromOptional(align_expr),
                    .addrspace_expr = .fromOptional(addrspace_expr),
                    .section_expr = .fromOptional(section_expr),
                    .callconv_expr = .fromOptional(callconv_expr),
                }),
                .fromOptional(return_type_expr),
            } },
        }),
        .multi => |span| {
            return p.setNode(fn_proto_index, .{
                .tag = .fn_proto,
                .main_token = fn_token,
                .data = .{ .extra_and_opt_node = .{
                    try p.addExtra(Node.FnProto{
                        .params_start = span.start,
                        .params_end = span.end,
                        .align_expr = .fromOptional(align_expr),
                        .addrspace_expr = .fromOptional(addrspace_expr),
                        .section_expr = .fromOptional(section_expr),
                        .callconv_expr = .fromOptional(callconv_expr),
                    }),
                    .fromOptional(return_type_expr),
                } },
            });
        },
    }
}

fn setVarDeclInitExpr(p: *Parse, var_decl: Node.Index, init_expr: Node.OptionalIndex) void {
    const init_expr_result = switch (p.nodeTag(var_decl)) {
        .simple_var_decl => &p.nodes.items(.data)[@intFromEnum(var_decl)].opt_node_and_opt_node[1],
        .aligned_var_decl => &p.nodes.items(.data)[@intFromEnum(var_decl)].node_and_opt_node[1],
        .local_var_decl, .global_var_decl => &p.nodes.items(.data)[@intFromEnum(var_decl)].extra_and_opt_node[1],
        else => unreachable,
    };
    init_expr_result.* = init_expr;
}

/// VarDeclProto <- (KEYWORD_const / KEYWORD_var) IDENTIFIER (COLON TypeExpr)? ByteAlign? AddrSpace? LinkSection?
/// Returns a `*_var_decl` node with its rhs (init expression) initialized to .none.
fn parseVarDeclProto(p: *Parse) !?Node.Index {
    const mut_token = p.eatToken(.keyword_const) orelse
        p.eatToken(.keyword_var) orelse
        return null;

    _ = try p.expectToken(.identifier);
    const opt_type_node = if (p.eatToken(.colon) == null) null else try p.expectTypeExpr();
    const opt_align_node = try p.parseByteAlign();
    const opt_addrspace_node = try p.parseAddrSpace();
    const opt_section_node = try p.parseLinkSection();

    if (opt_section_node == null and opt_addrspace_node == null) {
        const align_node = opt_align_node orelse {
            return try p.addNode(.{
                .tag = .simple_var_decl,
                .main_token = mut_token,
                .data = .{
                    .opt_node_and_opt_node = .{
                        .fromOptional(opt_type_node),
                        .none, // set later with `setVarDeclInitExpr
                    },
                },
            });
        };

        const type_node = opt_type_node orelse {
            return try p.addNode(.{
                .tag = .aligned_var_decl,
                .main_token = mut_token,
                .data = .{
                    .node_and_opt_node = .{
                        align_node,
                        .none, // set later with `setVarDeclInitExpr
                    },
                },
            });
        };

        return try p.addNode(.{
            .tag = .local_var_decl,
            .main_token = mut_token,
            .data = .{
                .extra_and_opt_node = .{
                    try p.addExtra(Node.LocalVarDecl{
                        .type_node = type_node,
                        .align_node = align_node,
                    }),
                    .none, // set later with `setVarDeclInitExpr
                },
            },
        });
    } else {
        return try p.addNode(.{
            .tag = .global_var_decl,
            .main_token = mut_token,
            .data = .{
                .extra_and_opt_node = .{
                    try p.addExtra(Node.GlobalVarDecl{
                        .type_node = .fromOptional(opt_type_node),
                        .align_node = .fromOptional(opt_align_node),
                        .addrspace_node = .fromOptional(opt_addrspace_node),
                        .section_node = .fromOptional(opt_section_node),
                    }),
                    .none, // set later with `setVarDeclInitExpr
                },
            },
        });
    }
}

/// GlobalVarDecl <- VarDeclProto (EQUAL Expr?) SEMICOLON
fn parseGlobalVarDecl(p: *Parse) !?Node.Index {
    const var_decl = try p.parseVarDeclProto() orelse return null;

    const init_node: ?Node.Index = switch (p.tokenTag(p.tok_i)) {
        .equal_equal => blk: {
            try p.warn(.wrong_equal_var_decl);
            p.tok_i += 1;
            break :blk try p.expectExpr();
        },
        .equal => blk: {
            p.tok_i += 1;
            break :blk try p.expectExpr();
        },
        else => null,
    };

    p.setVarDeclInitExpr(var_decl, .fromOptional(init_node));

    try p.expectSemicolon(.expected_semi_after_decl, false);
    return var_decl;
}

/// ContainerField <- doc_comment? KEYWORD_comptime? !KEYWORD_fn (IDENTIFIER COLON)? TypeExpr ByteAlign? (EQUAL Expr)?
fn expectContainerField(p: *Parse) !Node.Index {
    _ = p.eatToken(.keyword_comptime);
    const main_token = p.tok_i;
    _ = p.eatTokens(&.{ .identifier, .colon });
    const type_expr = try p.expectTypeExpr();
    const align_expr = try p.parseByteAlign();
    const value_expr = if (p.eatToken(.equal) == null) null else try p.expectExpr();

    if (align_expr == null) {
        return p.addNode(.{
            .tag = .container_field_init,
            .main_token = main_token,
            .data = .{ .node_and_opt_node = .{
                type_expr,
                .fromOptional(value_expr),
            } },
        });
    } else if (value_expr == null) {
        return p.addNode(.{
            .tag = .container_field_align,
            .main_token = main_token,
            .data = .{ .node_and_node = .{
                type_expr,
                align_expr.?,
            } },
        });
    } else {
        return p.addNode(.{
            .tag = .container_field,
            .main_token = main_token,
            .data = .{ .node_and_extra = .{
                type_expr, try p.addExtra(Node.ContainerField{
                    .align_expr = align_expr.?,
                    .value_expr = value_expr.?,
                }),
            } },
        });
    }
}

/// Statement
///     <- KEYWORD_comptime ComptimeStatement
///      / KEYWORD_nosuspend BlockExprStatement
///      / KEYWORD_suspend BlockExprStatement
///      / KEYWORD_defer BlockExprStatement
///      / KEYWORD_errdefer Payload? BlockExprStatement
///      / IfStatement
///      / LabeledStatement
///      / VarDeclExprStatement
fn expectStatement(p: *Parse, allow_defer_var: bool) Error!Node.Index {
    if (p.eatToken(.keyword_comptime)) |comptime_token| {
        const opt_block_expr = try p.parseBlockExpr();
        if (opt_block_expr) |block_expr| {
            return p.addNode(.{
                .tag = .@"comptime",
                .main_token = comptime_token,
                .data = .{ .node = block_expr },
            });
        }

        if (allow_defer_var) {
            return p.expectVarDeclExprStatement(comptime_token);
        } else {
            const assign = try p.expectAssignExpr();
            try p.expectSemicolon(.expected_semi_after_stmt, true);
            return p.addNode(.{
                .tag = .@"comptime",
                .main_token = comptime_token,
                .data = .{ .node = assign },
            });
        }
    }

    switch (p.tokenTag(p.tok_i)) {
        .keyword_nosuspend => {
            return p.addNode(.{
                .tag = .@"nosuspend",
                .main_token = p.nextToken(),
                .data = .{ .node = try p.expectBlockExprStatement() },
            });
        },
        .keyword_suspend => {
            const token = p.nextToken();
            const block_expr = try p.expectBlockExprStatement();
            return p.addNode(.{
                .tag = .@"suspend",
                .main_token = token,
                .data = .{ .node = block_expr },
            });
        },
        .keyword_defer => if (allow_defer_var) return p.addNode(.{
            .tag = .@"defer",
            .main_token = p.nextToken(),
            .data = .{ .node = try p.expectBlockExprStatement() },
        }),
        .keyword_errdefer => if (allow_defer_var) return p.addNode(.{
            .tag = .@"errdefer",
            .main_token = p.nextToken(),
            .data = .{ .opt_token_and_node = .{
                try p.parsePayload(),
                try p.expectBlockExprStatement(),
            } },
        }),
        .keyword_if => return p.expectIfStatement(),
        .keyword_enum, .keyword_struct, .keyword_union => {
            const identifier = p.tok_i + 1;
            if (try p.parseCStyleContainer()) {
                // Return something so that `expectStatement` is happy.
                return p.addNode(.{
                    .tag = .identifier,
                    .main_token = identifier,
                    .data = undefined,
                });
            }
        },
        else => {},
    }

    if (try p.parseLabeledStatement()) |labeled_statement| return labeled_statement;

    if (allow_defer_var) {
        return p.expectVarDeclExprStatement(null);
    } else {
        const assign = try p.expectAssignExpr();
        try p.expectSemicolon(.expected_semi_after_stmt, true);
        return assign;
    }
}

/// ComptimeStatement
///     <- BlockExpr
///      / VarDeclExprStatement
fn expectComptimeStatement(p: *Parse, comptime_token: TokenIndex) !Node.Index {
    const maybe_block_expr = try p.parseBlockExpr();
    if (maybe_block_expr) |block_expr| {
        return p.addNode(.{
            .tag = .@"comptime",
            .main_token = comptime_token,
            .data = .{
                .lhs = .{ .node = block_expr },
                .rhs = undefined,
            },
        });
    }
    return p.expectVarDeclExprStatement(comptime_token);
}

/// VarDeclExprStatement
///    <- VarDeclProto (COMMA (VarDeclProto / Expr))* EQUAL Expr SEMICOLON
///     / Expr (AssignOp Expr / (COMMA (VarDeclProto / Expr))+ EQUAL Expr)? SEMICOLON
fn expectVarDeclExprStatement(p: *Parse, comptime_token: ?TokenIndex) !Node.Index {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        const opt_var_decl_proto = try p.parseVarDeclProto();
        if (opt_var_decl_proto) |var_decl| {
            try p.scratch.append(p.gpa, var_decl);
        } else {
            const expr = try p.parseExpr() orelse {
                if (p.scratch.items.len == scratch_top) {
                    // We parsed nothing
                    return p.fail(.expected_statement);
                } else {
                    // We've had at least one LHS, but had a bad comma
                    return p.fail(.expected_expr_or_var_decl);
                }
            };
            try p.scratch.append(p.gpa, expr);
        }
        _ = p.eatToken(.comma) orelse break;
    }

    const lhs_count = p.scratch.items.len - scratch_top;
    assert(lhs_count > 0);

    const equal_token = p.eatToken(.equal) orelse eql: {
        if (lhs_count > 1) {
            // Definitely a destructure, so allow recovering from ==
            if (p.eatToken(.equal_equal)) |tok| {
                try p.warnMsg(.{ .tag = .wrong_equal_var_decl, .token = tok });
                break :eql tok;
            }
            return p.failExpected(.equal);
        }
        const lhs = p.scratch.items[scratch_top];
        switch (p.nodeTag(lhs)) {
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                // Definitely a var decl, so allow recovering from ==
                if (p.eatToken(.equal_equal)) |tok| {
                    try p.warnMsg(.{ .tag = .wrong_equal_var_decl, .token = tok });
                    break :eql tok;
                }
                return p.failExpected(.equal);
            },
            else => {},
        }

        const expr = try p.finishAssignExpr(lhs);
        try p.expectSemicolon(.expected_semi_after_stmt, true);
        if (comptime_token) |t| {
            return p.addNode(.{
                .tag = .@"comptime",
                .main_token = t,
                .data = .{ .node = expr },
            });
        } else {
            return expr;
        }
    };

    const rhs = try p.expectExpr();
    try p.expectSemicolon(.expected_semi_after_stmt, true);

    if (lhs_count == 1) {
        const lhs = p.scratch.items[scratch_top];
        switch (p.nodeTag(lhs)) {
            .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
                p.setVarDeclInitExpr(lhs, rhs.toOptional());
                // Don't need to wrap in comptime
                return lhs;
            },
            else => {},
        }
        const expr = try p.addNode(.{
            .tag = .assign,
            .main_token = equal_token,
            .data = .{ .node_and_node = .{
                lhs,
                rhs,
            } },
        });
        if (comptime_token) |t| {
            return p.addNode(.{
                .tag = .@"comptime",
                .main_token = t,
                .data = .{ .node = expr },
            });
        } else {
            return expr;
        }
    }

    // An actual destructure! No need for any `comptime` wrapper here.

    const extra_start: ExtraIndex = @enumFromInt(p.extra_data.items.len);
    try p.extra_data.ensureUnusedCapacity(p.gpa, lhs_count + 1);
    p.extra_data.appendAssumeCapacity(@intCast(lhs_count));
    p.extra_data.appendSliceAssumeCapacity(@ptrCast(p.scratch.items[scratch_top..]));

    return p.addNode(.{
        .tag = .assign_destructure,
        .main_token = equal_token,
        .data = .{ .extra_and_node = .{
            extra_start,
            rhs,
        } },
    });
}

/// If a parse error occurs, reports an error, but then finds the next statement
/// and returns that one instead. If a parse error occurs but there is no following
/// statement, returns 0.
fn expectStatementRecoverable(p: *Parse) Error!?Node.Index {
    while (true) {
        return p.expectStatement(true) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {
                p.findNextStmt(); // Try to skip to the next statement.
                switch (p.tokenTag(p.tok_i)) {
                    .r_brace => return null,
                    .eof => return error.ParseError,
                    else => continue,
                }
            },
        };
    }
}

/// IfStatement
///     <- IfPrefix BlockExpr ( KEYWORD_else Payload? Statement )?
///      / IfPrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
fn expectIfStatement(p: *Parse) !Node.Index {
    const if_token = p.assertToken(.keyword_if);
    _ = try p.expectToken(.l_paren);
    const condition = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    _ = try p.parsePtrPayload();

    // TODO propose to change the syntax so that semicolons are always required
    // inside if statements, even if there is an `else`.
    var else_required = false;
    const then_expr = blk: {
        const block_expr = try p.parseBlockExpr();
        if (block_expr) |block| break :blk block;
        const assign_expr = try p.parseAssignExpr() orelse {
            return p.fail(.expected_block_or_assignment);
        };
        if (p.eatToken(.semicolon)) |_| {
            return p.addNode(.{
                .tag = .if_simple,
                .main_token = if_token,
                .data = .{ .node_and_node = .{
                    condition,
                    assign_expr,
                } },
            });
        }
        else_required = true;
        break :blk assign_expr;
    };
    _ = p.eatToken(.keyword_else) orelse {
        if (else_required) {
            try p.warn(.expected_semi_or_else);
        }
        return p.addNode(.{
            .tag = .if_simple,
            .main_token = if_token,
            .data = .{ .node_and_node = .{
                condition,
                then_expr,
            } },
        });
    };
    _ = try p.parsePayload();
    const else_expr = try p.expectStatement(false);
    return p.addNode(.{
        .tag = .@"if",
        .main_token = if_token,
        .data = .{ .node_and_extra = .{
            condition, try p.addExtra(Node.If{
                .then_expr = then_expr,
                .else_expr = else_expr,
            }),
        } },
    });
}

/// LabeledStatement <- BlockLabel? (Block / LoopStatement / SwitchExpr)
fn parseLabeledStatement(p: *Parse) !?Node.Index {
    const opt_label_token = p.parseBlockLabel();

    if (try p.parseBlock()) |block| return block;
    if (try p.parseLoopStatement()) |loop_stmt| return loop_stmt;
    if (try p.parseSwitchExpr(opt_label_token != null)) |switch_expr| return switch_expr;

    const label_token = opt_label_token orelse return null;

    const after_colon = p.tok_i;
    if (try p.parseTypeExpr()) |_| {
        const a = try p.parseByteAlign();
        const b = try p.parseAddrSpace();
        const c = try p.parseLinkSection();
        const d = if (p.eatToken(.equal) == null) null else try p.expectExpr();
        if (a != null or b != null or c != null or d != null) {
            return p.failMsg(.{ .tag = .expected_var_const, .token = label_token });
        }
    }
    return p.failMsg(.{ .tag = .expected_labelable, .token = after_colon });
}

/// LoopStatement <- KEYWORD_inline? (ForStatement / WhileStatement)
fn parseLoopStatement(p: *Parse) !?Node.Index {
    const inline_token = p.eatToken(.keyword_inline);

    if (try p.parseForStatement()) |for_statement| return for_statement;
    if (try p.parseWhileStatement()) |while_statement| return while_statement;

    if (inline_token == null) return null;

    // If we've seen "inline", there should have been a "for" or "while"
    return p.fail(.expected_inlinable);
}

/// ForStatement
///     <- ForPrefix BlockExpr ( KEYWORD_else Statement )?
///      / ForPrefix AssignExpr ( SEMICOLON / KEYWORD_else Statement )
fn parseForStatement(p: *Parse) !?Node.Index {
    const for_token = p.eatToken(.keyword_for) orelse return null;

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    const inputs = try p.forPrefix();

    var else_required = false;
    var seen_semicolon = false;
    const then_expr = blk: {
        const block_expr = try p.parseBlockExpr();
        if (block_expr) |block| break :blk block;
        const assign_expr = try p.parseAssignExpr() orelse {
            return p.fail(.expected_block_or_assignment);
        };
        if (p.eatToken(.semicolon)) |_| {
            seen_semicolon = true;
            break :blk assign_expr;
        }
        else_required = true;
        break :blk assign_expr;
    };
    var has_else = false;
    if (!seen_semicolon and p.eatToken(.keyword_else) != null) {
        try p.scratch.append(p.gpa, then_expr);
        const else_stmt = try p.expectStatement(false);
        try p.scratch.append(p.gpa, else_stmt);
        has_else = true;
    } else if (inputs == 1) {
        if (else_required) try p.warn(.expected_semi_or_else);
        return try p.addNode(.{
            .tag = .for_simple,
            .main_token = for_token,
            .data = .{ .node_and_node = .{
                p.scratch.items[scratch_top],
                then_expr,
            } },
        });
    } else {
        if (else_required) try p.warn(.expected_semi_or_else);
        try p.scratch.append(p.gpa, then_expr);
    }
    return try p.addNode(.{
        .tag = .@"for",
        .main_token = for_token,
        .data = .{ .@"for" = .{
            (try p.listToSpan(p.scratch.items[scratch_top..])).start,
            .{ .inputs = @intCast(inputs), .has_else = has_else },
        } },
    });
}

/// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
///
/// WhileStatement
///     <- WhilePrefix BlockExpr ( KEYWORD_else Payload? Statement )?
///      / WhilePrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
fn parseWhileStatement(p: *Parse) !?Node.Index {
    const while_token = p.eatToken(.keyword_while) orelse return null;
    _ = try p.expectToken(.l_paren);
    const condition = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    _ = try p.parsePtrPayload();
    const cont_expr = try p.parseWhileContinueExpr();

    // TODO propose to change the syntax so that semicolons are always required
    // inside while statements, even if there is an `else`.
    var else_required = false;
    const then_expr = blk: {
        const block_expr = try p.parseBlockExpr();
        if (block_expr) |block| break :blk block;
        const assign_expr = try p.parseAssignExpr() orelse {
            return p.fail(.expected_block_or_assignment);
        };
        if (p.eatToken(.semicolon)) |_| {
            if (cont_expr == null) {
                return try p.addNode(.{
                    .tag = .while_simple,
                    .main_token = while_token,
                    .data = .{ .node_and_node = .{
                        condition,
                        assign_expr,
                    } },
                });
            } else {
                return try p.addNode(.{
                    .tag = .while_cont,
                    .main_token = while_token,
                    .data = .{ .node_and_extra = .{
                        condition,
                        try p.addExtra(Node.WhileCont{
                            .cont_expr = cont_expr.?,
                            .then_expr = assign_expr,
                        }),
                    } },
                });
            }
        }
        else_required = true;
        break :blk assign_expr;
    };
    _ = p.eatToken(.keyword_else) orelse {
        if (else_required) {
            try p.warn(.expected_semi_or_else);
        }
        if (cont_expr == null) {
            return try p.addNode(.{
                .tag = .while_simple,
                .main_token = while_token,
                .data = .{ .node_and_node = .{
                    condition,
                    then_expr,
                } },
            });
        } else {
            return try p.addNode(.{
                .tag = .while_cont,
                .main_token = while_token,
                .data = .{ .node_and_extra = .{
                    condition,
                    try p.addExtra(Node.WhileCont{
                        .cont_expr = cont_expr.?,
                        .then_expr = then_expr,
                    }),
                } },
            });
        }
    };
    _ = try p.parsePayload();
    const else_expr = try p.expectStatement(false);
    return try p.addNode(.{
        .tag = .@"while",
        .main_token = while_token,
        .data = .{ .node_and_extra = .{
            condition, try p.addExtra(Node.While{
                .cont_expr = .fromOptional(cont_expr),
                .then_expr = then_expr,
                .else_expr = else_expr,
            }),
        } },
    });
}

/// BlockExprStatement
///     <- BlockExpr
///      / AssignExpr SEMICOLON
fn parseBlockExprStatement(p: *Parse) !?Node.Index {
    const block_expr = try p.parseBlockExpr();
    if (block_expr) |expr| return expr;
    const assign_expr = try p.parseAssignExpr();
    if (assign_expr) |expr| {
        try p.expectSemicolon(.expected_semi_after_stmt, true);
        return expr;
    }
    return null;
}

fn expectBlockExprStatement(p: *Parse) !Node.Index {
    return try p.parseBlockExprStatement() orelse return p.fail(.expected_block_or_expr);
}

/// BlockExpr <- BlockLabel? Block
fn parseBlockExpr(p: *Parse) Error!?Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .identifier => {
            if (p.tokenTag(p.tok_i + 1) == .colon and
                p.tokenTag(p.tok_i + 2) == .l_brace)
            {
                p.tok_i += 2;
                return p.parseBlock();
            } else {
                return null;
            }
        },
        .l_brace => return p.parseBlock(),
        else => return null,
    }
}

/// AssignExpr <- Expr (AssignOp Expr / (COMMA Expr)+ EQUAL Expr)?
///
/// AssignOp
///     <- ASTERISKEQUAL
///      / ASTERISKPIPEEQUAL
///      / SLASHEQUAL
///      / PERCENTEQUAL
///      / PLUSEQUAL
///      / PLUSPIPEEQUAL
///      / MINUSEQUAL
///      / MINUSPIPEEQUAL
///      / LARROW2EQUAL
///      / LARROW2PIPEEQUAL
///      / RARROW2EQUAL
///      / AMPERSANDEQUAL
///      / CARETEQUAL
///      / PIPEEQUAL
///      / ASTERISKPERCENTEQUAL
///      / PLUSPERCENTEQUAL
///      / MINUSPERCENTEQUAL
///      / EQUAL
fn parseAssignExpr(p: *Parse) !?Node.Index {
    const expr = try p.parseExpr() orelse return null;
    return try p.finishAssignExpr(expr);
}

/// SingleAssignExpr <- Expr (AssignOp Expr)?
fn parseSingleAssignExpr(p: *Parse) !?Node.Index {
    const lhs = try p.parseExpr() orelse return null;
    const tag = assignOpNode(p.tokenTag(p.tok_i)) orelse return lhs;
    return try p.addNode(.{
        .tag = tag,
        .main_token = p.nextToken(),
        .data = .{ .node_and_node = .{
            lhs,
            try p.expectExpr(),
        } },
    });
}

fn finishAssignExpr(p: *Parse, lhs: Node.Index) !Node.Index {
    const tok = p.tokenTag(p.tok_i);
    if (tok == .comma) return p.finishAssignDestructureExpr(lhs);
    const tag = assignOpNode(tok) orelse return lhs;
    return p.addNode(.{
        .tag = tag,
        .main_token = p.nextToken(),
        .data = .{ .node_and_node = .{
            lhs,
            try p.expectExpr(),
        } },
    });
}

fn assignOpNode(tok: Token.Tag) ?Node.Tag {
    return switch (tok) {
        .asterisk_equal => .assign_mul,
        .slash_equal => .assign_div,
        .percent_equal => .assign_mod,
        .plus_equal => .assign_add,
        .minus_equal => .assign_sub,
        .angle_bracket_angle_bracket_left_equal => .assign_shl,
        .angle_bracket_angle_bracket_left_pipe_equal => .assign_shl_sat,
        .angle_bracket_angle_bracket_right_equal => .assign_shr,
        .ampersand_equal => .assign_bit_and,
        .caret_equal => .assign_bit_xor,
        .pipe_equal => .assign_bit_or,
        .asterisk_percent_equal => .assign_mul_wrap,
        .plus_percent_equal => .assign_add_wrap,
        .minus_percent_equal => .assign_sub_wrap,
        .asterisk_pipe_equal => .assign_mul_sat,
        .plus_pipe_equal => .assign_add_sat,
        .minus_pipe_equal => .assign_sub_sat,
        .equal => .assign,
        else => null,
    };
}

fn finishAssignDestructureExpr(p: *Parse, first_lhs: Node.Index) !Node.Index {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    try p.scratch.append(p.gpa, first_lhs);

    while (p.eatToken(.comma)) |_| {
        const expr = try p.expectExpr();
        try p.scratch.append(p.gpa, expr);
    }

    const equal_token = try p.expectToken(.equal);

    const rhs = try p.expectExpr();

    const lhs_count = p.scratch.items.len - scratch_top;
    assert(lhs_count > 1); // we already had first_lhs, and must have at least one more lvalue

    const extra_start: ExtraIndex = @enumFromInt(p.extra_data.items.len);
    try p.extra_data.ensureUnusedCapacity(p.gpa, lhs_count + 1);
    p.extra_data.appendAssumeCapacity(@intCast(lhs_count));
    p.extra_data.appendSliceAssumeCapacity(@ptrCast(p.scratch.items[scratch_top..]));

    return p.addNode(.{
        .tag = .assign_destructure,
        .main_token = equal_token,
        .data = .{ .extra_and_node = .{
            extra_start,
            rhs,
        } },
    });
}

fn expectSingleAssignExpr(p: *Parse) !Node.Index {
    return try p.parseSingleAssignExpr() orelse return p.fail(.expected_expr_or_assignment);
}

fn expectAssignExpr(p: *Parse) !Node.Index {
    return try p.parseAssignExpr() orelse return p.fail(.expected_expr_or_assignment);
}

fn parseExpr(p: *Parse) Error!?Node.Index {
    return p.parseExprPrecedence(0);
}

fn expectExpr(p: *Parse) Error!Node.Index {
    return try p.parseExpr() orelse return p.fail(.expected_expr);
}

const Assoc = enum {
    left,
    none,
};

const OperInfo = struct {
    prec: i8,
    tag: Node.Tag,
    assoc: Assoc = Assoc.left,
};

// A table of binary operator information. Higher precedence numbers are
// stickier. All operators at the same precedence level should have the same
// associativity.
const operTable = std.enums.directEnumArrayDefault(Token.Tag, OperInfo, .{ .prec = -1, .tag = Node.Tag.root }, 0, .{
    .keyword_or = .{ .prec = 10, .tag = .bool_or },

    .keyword_and = .{ .prec = 20, .tag = .bool_and },

    .equal_equal = .{ .prec = 30, .tag = .equal_equal, .assoc = Assoc.none },
    .bang_equal = .{ .prec = 30, .tag = .bang_equal, .assoc = Assoc.none },
    .angle_bracket_left = .{ .prec = 30, .tag = .less_than, .assoc = Assoc.none },
    .angle_bracket_right = .{ .prec = 30, .tag = .greater_than, .assoc = Assoc.none },
    .angle_bracket_left_equal = .{ .prec = 30, .tag = .less_or_equal, .assoc = Assoc.none },
    .angle_bracket_right_equal = .{ .prec = 30, .tag = .greater_or_equal, .assoc = Assoc.none },

    .ampersand = .{ .prec = 40, .tag = .bit_and },
    .caret = .{ .prec = 40, .tag = .bit_xor },
    .pipe = .{ .prec = 40, .tag = .bit_or },
    .keyword_orelse = .{ .prec = 40, .tag = .@"orelse" },
    .keyword_catch = .{ .prec = 40, .tag = .@"catch" },

    .angle_bracket_angle_bracket_left = .{ .prec = 50, .tag = .shl },
    .angle_bracket_angle_bracket_left_pipe = .{ .prec = 50, .tag = .shl_sat },
    .angle_bracket_angle_bracket_right = .{ .prec = 50, .tag = .shr },

    .plus = .{ .prec = 60, .tag = .add },
    .minus = .{ .prec = 60, .tag = .sub },
    .plus_plus = .{ .prec = 60, .tag = .array_cat },
    .plus_percent = .{ .prec = 60, .tag = .add_wrap },
    .minus_percent = .{ .prec = 60, .tag = .sub_wrap },
    .plus_pipe = .{ .prec = 60, .tag = .add_sat },
    .minus_pipe = .{ .prec = 60, .tag = .sub_sat },

    .pipe_pipe = .{ .prec = 70, .tag = .merge_error_sets },
    .asterisk = .{ .prec = 70, .tag = .mul },
    .slash = .{ .prec = 70, .tag = .div },
    .percent = .{ .prec = 70, .tag = .mod },
    .asterisk_asterisk = .{ .prec = 70, .tag = .array_mult },
    .asterisk_percent = .{ .prec = 70, .tag = .mul_wrap },
    .asterisk_pipe = .{ .prec = 70, .tag = .mul_sat },
});

fn parseExprPrecedence(p: *Parse, min_prec: i32) Error!?Node.Index {
    assert(min_prec >= 0);
    var node = try p.parsePrefixExpr() orelse return null;

    var banned_prec: i8 = -1;

    while (true) {
        const tok_tag = p.tokenTag(p.tok_i);
        const info = operTable[@as(usize, @intCast(@intFromEnum(tok_tag)))];
        if (info.prec < min_prec) {
            break;
        }
        if (info.prec == banned_prec) {
            return p.fail(.chained_comparison_operators);
        }

        const oper_token = p.nextToken();
        // Special-case handling for "catch"
        if (tok_tag == .keyword_catch) {
            _ = try p.parsePayload();
        }
        const rhs = try p.parseExprPrecedence(info.prec + 1) orelse {
            try p.warn(.expected_expr);
            return node;
        };

        {
            const tok_len = tok_tag.lexeme().?.len;
            const char_before = p.source[p.tokenStart(oper_token) - 1];
            const char_after = p.source[p.tokenStart(oper_token) + tok_len];
            if (tok_tag == .ampersand and char_after == '&') {
                // without types we don't know if '&&' was intended as 'bitwise_and address_of', or a c-style logical_and
                // The best the parser can do is recommend changing it to 'and' or ' & &'
                try p.warnMsg(.{ .tag = .invalid_ampersand_ampersand, .token = oper_token });
            } else if (std.ascii.isWhitespace(char_before) != std.ascii.isWhitespace(char_after)) {
                try p.warnMsg(.{ .tag = .mismatched_binary_op_whitespace, .token = oper_token });
            }
        }

        node = try p.addNode(.{
            .tag = info.tag,
            .main_token = oper_token,
            .data = .{ .node_and_node = .{ node, rhs } },
        });

        if (info.assoc == Assoc.none) {
            banned_prec = info.prec;
        }
    }

    return node;
}

/// PrefixExpr <- PrefixOp* PrimaryExpr
///
/// PrefixOp
///     <- EXCLAMATIONMARK
///      / MINUS
///      / TILDE
///      / MINUSPERCENT
///      / AMPERSAND
///      / KEYWORD_try
fn parsePrefixExpr(p: *Parse) Error!?Node.Index {
    const tag: Node.Tag = switch (p.tokenTag(p.tok_i)) {
        .bang => .bool_not,
        .minus => .negation,
        .tilde => .bit_not,
        .minus_percent => .negation_wrap,
        .ampersand => .address_of,
        .keyword_try => .@"try",
        else => return p.parsePrimaryExpr(),
    };
    return try p.addNode(.{
        .tag = tag,
        .main_token = p.nextToken(),
        .data = .{ .node = try p.expectPrefixExpr() },
    });
}

fn expectPrefixExpr(p: *Parse) Error!Node.Index {
    return try p.parsePrefixExpr() orelse return p.fail(.expected_prefix_expr);
}

/// TypeExpr <- PrefixTypeOp* ErrorUnionExpr
///
/// PrefixTypeOp
///     <- QUESTIONMARK
///      / KEYWORD_anyframe MINUSRARROW
///      / SliceTypeStart (ByteAlign / AddrSpace / KEYWORD_const / KEYWORD_volatile / KEYWORD_allowzero)*
///      / PtrTypeStart (AddrSpace / KEYWORD_align LPAREN Expr (COLON Expr COLON Expr)? RPAREN / KEYWORD_const / KEYWORD_volatile / KEYWORD_allowzero)*
///      / ArrayTypeStart
///
/// SliceTypeStart <- LBRACKET (COLON Expr)? RBRACKET
///
/// PtrTypeStart
///     <- ASTERISK
///      / ASTERISK2
///      / LBRACKET ASTERISK (LETTERC / COLON Expr)? RBRACKET
///
/// ArrayTypeStart <- LBRACKET Expr (COLON Expr)? RBRACKET
fn parseTypeExpr(p: *Parse) Error!?Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .question_mark => return try p.addNode(.{
            .tag = .optional_type,
            .main_token = p.nextToken(),
            .data = .{ .node = try p.expectTypeExpr() },
        }),
        .keyword_anyframe => switch (p.tokenTag(p.tok_i + 1)) {
            .arrow => return try p.addNode(.{
                .tag = .anyframe_type,
                .main_token = p.nextToken(),
                .data = .{ .token_and_node = .{
                    p.nextToken(),
                    try p.expectTypeExpr(),
                } },
            }),
            else => return try p.parseErrorUnionExpr(),
        },
        .asterisk => {
            const asterisk = p.nextToken();
            const mods = try p.parsePtrModifiers();
            const elem_type = try p.expectTypeExpr();
            if (mods.bit_range_start != .none) {
                return try p.addNode(.{
                    .tag = .ptr_type_bit_range,
                    .main_token = asterisk,
                    .data = .{ .extra_and_node = .{
                        try p.addExtra(Node.PtrTypeBitRange{
                            .sentinel = .none,
                            .align_node = mods.align_node.unwrap().?,
                            .addrspace_node = mods.addrspace_node,
                            .bit_range_start = mods.bit_range_start.unwrap().?,
                            .bit_range_end = mods.bit_range_end.unwrap().?,
                        }),
                        elem_type,
                    } },
                });
            } else if (mods.addrspace_node != .none) {
                return try p.addNode(.{
                    .tag = .ptr_type,
                    .main_token = asterisk,
                    .data = .{ .extra_and_node = .{
                        try p.addExtra(Node.PtrType{
                            .sentinel = .none,
                            .align_node = mods.align_node,
                            .addrspace_node = mods.addrspace_node,
                        }),
                        elem_type,
                    } },
                });
            } else {
                return try p.addNode(.{
                    .tag = .ptr_type_aligned,
                    .main_token = asterisk,
                    .data = .{ .opt_node_and_node = .{
                        mods.align_node,
                        elem_type,
                    } },
                });
            }
        },
        .asterisk_asterisk => {
            const asterisk = p.nextToken();
            const mods = try p.parsePtrModifiers();
            const elem_type = try p.expectTypeExpr();
            const inner: Node.Index = inner: {
                if (mods.bit_range_start != .none) {
                    break :inner try p.addNode(.{
                        .tag = .ptr_type_bit_range,
                        .main_token = asterisk,
                        .data = .{ .extra_and_node = .{
                            try p.addExtra(Node.PtrTypeBitRange{
                                .sentinel = .none,
                                .align_node = mods.align_node.unwrap().?,
                                .addrspace_node = mods.addrspace_node,
                                .bit_range_start = mods.bit_range_start.unwrap().?,
                                .bit_range_end = mods.bit_range_end.unwrap().?,
                            }),
                            elem_type,
                        } },
                    });
                } else if (mods.addrspace_node != .none) {
                    break :inner try p.addNode(.{
                        .tag = .ptr_type,
                        .main_token = asterisk,
                        .data = .{ .extra_and_node = .{
                            try p.addExtra(Node.PtrType{
                                .sentinel = .none,
                                .align_node = mods.align_node,
                                .addrspace_node = mods.addrspace_node,
                            }),
                            elem_type,
                        } },
                    });
                } else {
                    break :inner try p.addNode(.{
                        .tag = .ptr_type_aligned,
                        .main_token = asterisk,
                        .data = .{ .opt_node_and_node = .{
                            mods.align_node,
                            elem_type,
                        } },
                    });
                }
            };
            return try p.addNode(.{
                .tag = .ptr_type_aligned,
                .main_token = asterisk,
                .data = .{ .opt_node_and_node = .{
                    .none,
                    inner,
                } },
            });
        },
        .l_bracket => switch (p.tokenTag(p.tok_i + 1)) {
            .asterisk => {
                const l_bracket = p.nextToken();
                _ = p.nextToken();
                var sentinel: ?Node.Index = null;
                if (p.eatToken(.identifier)) |ident| {
                    const ident_slice = p.source[p.tokenStart(ident)..p.tokenStart(ident + 1)];
                    if (!std.mem.eql(u8, std.mem.trimEnd(u8, ident_slice, &std.ascii.whitespace), "c")) {
                        p.tok_i -= 1;
                    }
                } else if (p.eatToken(.colon)) |_| {
                    sentinel = try p.expectExpr();
                }
                _ = try p.expectToken(.r_bracket);
                const mods = try p.parsePtrModifiers();
                const elem_type = try p.expectTypeExpr();
                if (mods.bit_range_start == .none) {
                    if (sentinel == null and mods.addrspace_node == .none) {
                        return try p.addNode(.{
                            .tag = .ptr_type_aligned,
                            .main_token = l_bracket,
                            .data = .{ .opt_node_and_node = .{
                                mods.align_node,
                                elem_type,
                            } },
                        });
                    } else if (mods.align_node == .none and mods.addrspace_node == .none) {
                        return try p.addNode(.{
                            .tag = .ptr_type_sentinel,
                            .main_token = l_bracket,
                            .data = .{ .opt_node_and_node = .{
                                .fromOptional(sentinel),
                                elem_type,
                            } },
                        });
                    } else {
                        return try p.addNode(.{
                            .tag = .ptr_type,
                            .main_token = l_bracket,
                            .data = .{ .extra_and_node = .{
                                try p.addExtra(Node.PtrType{
                                    .sentinel = .fromOptional(sentinel),
                                    .align_node = mods.align_node,
                                    .addrspace_node = mods.addrspace_node,
                                }),
                                elem_type,
                            } },
                        });
                    }
                } else {
                    return try p.addNode(.{
                        .tag = .ptr_type_bit_range,
                        .main_token = l_bracket,
                        .data = .{ .extra_and_node = .{
                            try p.addExtra(Node.PtrTypeBitRange{
                                .sentinel = .fromOptional(sentinel),
                                .align_node = mods.align_node.unwrap().?,
                                .addrspace_node = mods.addrspace_node,
                                .bit_range_start = mods.bit_range_start.unwrap().?,
                                .bit_range_end = mods.bit_range_end.unwrap().?,
                            }),
                            elem_type,
                        } },
                    });
                }
            },
            else => {
                const lbracket = p.nextToken();
                const len_expr = try p.parseExpr();
                const sentinel: ?Node.Index = if (p.eatToken(.colon)) |_|
                    try p.expectExpr()
                else
                    null;
                _ = try p.expectToken(.r_bracket);
                if (len_expr == null) {
                    const mods = try p.parsePtrModifiers();
                    const elem_type = try p.expectTypeExpr();
                    if (mods.bit_range_start.unwrap()) |bit_range_start| {
                        try p.warnMsg(.{
                            .tag = .invalid_bit_range,
                            .token = p.nodeMainToken(bit_range_start),
                        });
                    }
                    if (sentinel == null and mods.addrspace_node == .none) {
                        return try p.addNode(.{
                            .tag = .ptr_type_aligned,
                            .main_token = lbracket,
                            .data = .{ .opt_node_and_node = .{
                                mods.align_node,
                                elem_type,
                            } },
                        });
                    } else if (mods.align_node == .none and mods.addrspace_node == .none) {
                        return try p.addNode(.{
                            .tag = .ptr_type_sentinel,
                            .main_token = lbracket,
                            .data = .{ .opt_node_and_node = .{
                                .fromOptional(sentinel),
                                elem_type,
                            } },
                        });
                    } else {
                        return try p.addNode(.{
                            .tag = .ptr_type,
                            .main_token = lbracket,
                            .data = .{ .extra_and_node = .{
                                try p.addExtra(Node.PtrType{
                                    .sentinel = .fromOptional(sentinel),
                                    .align_node = mods.align_node,
                                    .addrspace_node = mods.addrspace_node,
                                }),
                                elem_type,
                            } },
                        });
                    }
                } else {
                    switch (p.tokenTag(p.tok_i)) {
                        .keyword_align,
                        .keyword_const,
                        .keyword_volatile,
                        .keyword_allowzero,
                        .keyword_addrspace,
                        => return p.fail(.ptr_mod_on_array_child_type),
                        else => {},
                    }
                    const elem_type = try p.expectTypeExpr();
                    if (sentinel == null) {
                        return try p.addNode(.{
                            .tag = .array_type,
                            .main_token = lbracket,
                            .data = .{ .node_and_node = .{
                                len_expr.?,
                                elem_type,
                            } },
                        });
                    } else {
                        return try p.addNode(.{
                            .tag = .array_type_sentinel,
                            .main_token = lbracket,
                            .data = .{ .node_and_extra = .{
                                len_expr.?, try p.addExtra(Node.ArrayTypeSentinel{
                                    .sentinel = sentinel.?,
                                    .elem_type = elem_type,
                                }),
                            } },
                        });
                    }
                }
            },
        },
        else => return p.parseErrorUnionExpr(),
    }
}

fn expectTypeExpr(p: *Parse) Error!Node.Index {
    return try p.parseTypeExpr() orelse return p.fail(.expected_type_expr);
}

/// PrimaryExpr
///     <- AsmExpr
///      / IfExpr
///      / KEYWORD_break BreakLabel? Expr?
///      / KEYWORD_comptime Expr
///      / KEYWORD_nosuspend Expr
///      / KEYWORD_continue BreakLabel? Expr?
///      / KEYWORD_resume Expr
///      / KEYWORD_return Expr?
///      / BlockLabel? LoopExpr
///      / Block
///      / CurlySuffixExpr
fn parsePrimaryExpr(p: *Parse) !?Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .keyword_asm => return try p.expectAsmExpr(),
        .keyword_if => return try p.parseIfExpr(),
        .keyword_break => {
            return try p.addNode(.{
                .tag = .@"break",
                .main_token = p.nextToken(),
                .data = .{ .opt_token_and_opt_node = .{
                    try p.parseBreakLabel(),
                    .fromOptional(try p.parseExpr()),
                } },
            });
        },
        .keyword_continue => {
            return try p.addNode(.{
                .tag = .@"continue",
                .main_token = p.nextToken(),
                .data = .{ .opt_token_and_opt_node = .{
                    try p.parseBreakLabel(),
                    .fromOptional(try p.parseExpr()),
                } },
            });
        },
        .keyword_comptime => {
            return try p.addNode(.{
                .tag = .@"comptime",
                .main_token = p.nextToken(),
                .data = .{ .node = try p.expectExpr() },
            });
        },
        .keyword_nosuspend => {
            return try p.addNode(.{
                .tag = .@"nosuspend",
                .main_token = p.nextToken(),
                .data = .{ .node = try p.expectExpr() },
            });
        },
        .keyword_resume => {
            return try p.addNode(.{
                .tag = .@"resume",
                .main_token = p.nextToken(),
                .data = .{ .node = try p.expectExpr() },
            });
        },
        .keyword_return => {
            return try p.addNode(.{
                .tag = .@"return",
                .main_token = p.nextToken(),
                .data = .{ .opt_node = .fromOptional(try p.parseExpr()) },
            });
        },
        .identifier => {
            if (p.tokenTag(p.tok_i + 1) == .colon) {
                switch (p.tokenTag(p.tok_i + 2)) {
                    .keyword_inline => {
                        p.tok_i += 3;
                        switch (p.tokenTag(p.tok_i)) {
                            .keyword_for => return try p.parseFor(expectExpr),
                            .keyword_while => return try p.parseWhileExpr(),
                            else => return p.fail(.expected_inlinable),
                        }
                    },
                    .keyword_for => {
                        p.tok_i += 2;
                        return try p.parseFor(expectExpr);
                    },
                    .keyword_while => {
                        p.tok_i += 2;
                        return try p.parseWhileExpr();
                    },
                    .l_brace => {
                        p.tok_i += 2;
                        return try p.parseBlock();
                    },
                    else => return try p.parseCurlySuffixExpr(),
                }
            } else {
                return try p.parseCurlySuffixExpr();
            }
        },
        .keyword_inline => {
            p.tok_i += 1;
            switch (p.tokenTag(p.tok_i)) {
                .keyword_for => return try p.parseFor(expectExpr),
                .keyword_while => return try p.parseWhileExpr(),
                else => return p.fail(.expected_inlinable),
            }
        },
        .keyword_for => return try p.parseFor(expectExpr),
        .keyword_while => return try p.parseWhileExpr(),
        .l_brace => return try p.parseBlock(),
        else => return try p.parseCurlySuffixExpr(),
    }
}

/// IfExpr <- IfPrefix Expr (KEYWORD_else Payload? Expr)?
fn parseIfExpr(p: *Parse) !?Node.Index {
    return try p.parseIf(expectExpr);
}

/// Block <- LBRACE Statement* RBRACE
fn parseBlock(p: *Parse) !?Node.Index {
    const lbrace = p.eatToken(.l_brace) orelse return null;
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (true) {
        if (p.tokenTag(p.tok_i) == .r_brace) break;
        const statement = try p.expectStatementRecoverable() orelse break;
        try p.scratch.append(p.gpa, statement);
    }
    _ = try p.expectToken(.r_brace);
    const statements = p.scratch.items[scratch_top..];
    const semicolon = statements.len != 0 and (p.tokenTag(p.tok_i - 2)) == .semicolon;
    if (statements.len <= 2) {
        return try p.addNode(.{
            .tag = if (semicolon) .block_two_semicolon else .block_two,
            .main_token = lbrace,
            .data = .{ .opt_node_and_opt_node = .{
                if (statements.len >= 1) statements[0].toOptional() else .none,
                if (statements.len >= 2) statements[1].toOptional() else .none,
            } },
        });
    } else {
        return try p.addNode(.{
            .tag = if (semicolon) .block_semicolon else .block,
            .main_token = lbrace,
            .data = .{ .extra_range = try p.listToSpan(statements) },
        });
    }
}

/// ForPrefix <- KEYWORD_for LPAREN ForInput (COMMA ForInput)* COMMA? RPAREN ForPayload
///
/// ForInput <- Expr (DOT2 Expr?)?
///
/// ForPayload <- PIPE ASTERISK? IDENTIFIER (COMMA ASTERISK? IDENTIFIER)* PIPE
fn forPrefix(p: *Parse) Error!usize {
    const start = p.scratch.items.len;
    _ = try p.expectToken(.l_paren);

    while (true) {
        var input = try p.expectExpr();
        if (p.eatToken(.ellipsis2)) |ellipsis| {
            input = try p.addNode(.{
                .tag = .for_range,
                .main_token = ellipsis,
                .data = .{ .node_and_opt_node = .{
                    input,
                    .fromOptional(try p.parseExpr()),
                } },
            });
        }

        try p.scratch.append(p.gpa, input);
        switch (p.tokenTag(p.tok_i)) {
            .comma => p.tok_i += 1,
            .r_paren => {
                p.tok_i += 1;
                break;
            },
            .colon, .r_brace, .r_bracket => return p.failExpected(.r_paren),
            // Likely just a missing comma; give error but continue parsing.
            else => try p.warn(.expected_comma_after_for_operand),
        }
        if (p.eatToken(.r_paren)) |_| break;
    }
    const inputs = p.scratch.items.len - start;

    _ = p.eatToken(.pipe) orelse {
        try p.warn(.expected_loop_payload);
        return inputs;
    };

    var warned_excess = false;
    var captures: u32 = 0;
    while (true) {
        _ = p.eatToken(.asterisk);
        const identifier = try p.expectToken(.identifier);
        captures += 1;
        if (captures > inputs and !warned_excess) {
            try p.warnMsg(.{ .tag = .extra_for_capture, .token = identifier });
            warned_excess = true;
        }
        switch (p.tokenTag(p.tok_i)) {
            .comma => p.tok_i += 1,
            .pipe => {
                p.tok_i += 1;
                break;
            },
            // Likely just a missing comma; give error but continue parsing.
            else => try p.warn(.expected_comma_after_capture),
        }
        if (p.eatToken(.pipe)) |_| break;
    }

    if (captures < inputs) {
        const index = p.scratch.items.len - captures;
        const input = p.nodeMainToken(p.scratch.items[index]);
        try p.warnMsg(.{ .tag = .for_input_not_captured, .token = input });
    }
    return inputs;
}

/// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
///
/// WhileExpr <- WhilePrefix Expr (KEYWORD_else Payload? Expr)?
fn parseWhileExpr(p: *Parse) !?Node.Index {
    const while_token = p.eatToken(.keyword_while) orelse return null;
    _ = try p.expectToken(.l_paren);
    const condition = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    _ = try p.parsePtrPayload();
    const cont_expr = try p.parseWhileContinueExpr();

    const then_expr = try p.expectExpr();
    _ = p.eatToken(.keyword_else) orelse {
        if (cont_expr == null) {
            return try p.addNode(.{
                .tag = .while_simple,
                .main_token = while_token,
                .data = .{ .node_and_node = .{
                    condition,
                    then_expr,
                } },
            });
        } else {
            return try p.addNode(.{
                .tag = .while_cont,
                .main_token = while_token,
                .data = .{ .node_and_extra = .{
                    condition,
                    try p.addExtra(Node.WhileCont{
                        .cont_expr = cont_expr.?,
                        .then_expr = then_expr,
                    }),
                } },
            });
        }
    };
    _ = try p.parsePayload();
    const else_expr = try p.expectExpr();
    return try p.addNode(.{
        .tag = .@"while",
        .main_token = while_token,
        .data = .{ .node_and_extra = .{
            condition,
            try p.addExtra(Node.While{
                .cont_expr = .fromOptional(cont_expr),
                .then_expr = then_expr,
                .else_expr = else_expr,
            }),
        } },
    });
}

/// CurlySuffixExpr <- TypeExpr InitList?
///
/// InitList
///     <- LBRACE FieldInit (COMMA FieldInit)* COMMA? RBRACE
///      / LBRACE Expr (COMMA Expr)* COMMA? RBRACE
///      / LBRACE RBRACE
fn parseCurlySuffixExpr(p: *Parse) !?Node.Index {
    const lhs = try p.parseTypeExpr() orelse return null;
    const lbrace = p.eatToken(.l_brace) orelse return lhs;

    // If there are 0 or 1 items, we can use ArrayInitOne/StructInitOne;
    // otherwise we use the full ArrayInit/StructInit.

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    const opt_field_init = try p.parseFieldInit();
    if (opt_field_init) |field_init| {
        try p.scratch.append(p.gpa, field_init);
        while (true) {
            switch (p.tokenTag(p.tok_i)) {
                .comma => p.tok_i += 1,
                .r_brace => {
                    p.tok_i += 1;
                    break;
                },
                .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                // Likely just a missing comma; give error but continue parsing.
                else => try p.warn(.expected_comma_after_initializer),
            }
            if (p.eatToken(.r_brace)) |_| break;
            const next = try p.expectFieldInit();
            try p.scratch.append(p.gpa, next);
        }
        const comma = (p.tokenTag(p.tok_i - 2)) == .comma;
        const inits = p.scratch.items[scratch_top..];
        std.debug.assert(inits.len != 0);
        if (inits.len <= 1) {
            return try p.addNode(.{
                .tag = if (comma) .struct_init_one_comma else .struct_init_one,
                .main_token = lbrace,
                .data = .{ .node_and_opt_node = .{
                    lhs,
                    inits[0].toOptional(),
                } },
            });
        } else {
            return try p.addNode(.{
                .tag = if (comma) .struct_init_comma else .struct_init,
                .main_token = lbrace,
                .data = .{ .node_and_extra = .{
                    lhs,
                    try p.addExtra(try p.listToSpan(inits)),
                } },
            });
        }
    }

    while (true) {
        if (p.eatToken(.r_brace)) |_| break;
        const elem_init = try p.expectExpr();
        try p.scratch.append(p.gpa, elem_init);
        switch (p.tokenTag(p.tok_i)) {
            .comma => p.tok_i += 1,
            .r_brace => {
                p.tok_i += 1;
                break;
            },
            .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
            // Likely just a missing comma; give error but continue parsing.
            else => try p.warn(.expected_comma_after_initializer),
        }
    }
    const comma = (p.tokenTag(p.tok_i - 2)) == .comma;
    const inits = p.scratch.items[scratch_top..];
    switch (inits.len) {
        0 => return try p.addNode(.{
            .tag = .struct_init_one,
            .main_token = lbrace,
            .data = .{ .node_and_opt_node = .{
                lhs,
                .none,
            } },
        }),
        1 => return try p.addNode(.{
            .tag = if (comma) .array_init_one_comma else .array_init_one,
            .main_token = lbrace,
            .data = .{ .node_and_node = .{
                lhs,
                inits[0],
            } },
        }),
        else => return try p.addNode(.{
            .tag = if (comma) .array_init_comma else .array_init,
            .main_token = lbrace,
            .data = .{ .node_and_extra = .{
                lhs,
                try p.addExtra(try p.listToSpan(inits)),
            } },
        }),
    }
}

/// ErrorUnionExpr <- SuffixExpr (EXCLAMATIONMARK TypeExpr)?
fn parseErrorUnionExpr(p: *Parse) !?Node.Index {
    const suffix_expr = try p.parseSuffixExpr() orelse return null;
    const bang = p.eatToken(.bang) orelse return suffix_expr;
    return try p.addNode(.{
        .tag = .error_union,
        .main_token = bang,
        .data = .{ .node_and_node = .{
            suffix_expr,
            try p.expectTypeExpr(),
        } },
    });
}

/// SuffixExpr
///     <- PrimaryTypeExpr (SuffixOp / FnCallArguments)*
///
/// FnCallArguments <- LPAREN ExprList RPAREN
///
/// ExprList <- (Expr COMMA)* Expr?
fn parseSuffixExpr(p: *Parse) !?Node.Index {
    var res = try p.parsePrimaryTypeExpr() orelse return null;
    while (true) {
        const opt_suffix_op = try p.parseSuffixOp(res);
        if (opt_suffix_op) |suffix_op| {
            res = suffix_op;
            continue;
        }
        const lparen = p.eatToken(.l_paren) orelse return res;
        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);
        while (true) {
            if (p.eatToken(.r_paren)) |_| break;
            const param = try p.expectExpr();
            try p.scratch.append(p.gpa, param);
            switch (p.tokenTag(p.tok_i)) {
                .comma => p.tok_i += 1,
                .r_paren => {
                    p.tok_i += 1;
                    break;
                },
                .colon, .r_brace, .r_bracket => return p.failExpected(.r_paren),
                // Likely just a missing comma; give error but continue parsing.
                else => try p.warn(.expected_comma_after_arg),
            }
        }
        const comma = (p.tokenTag(p.tok_i - 2)) == .comma;
        const params = p.scratch.items[scratch_top..];
        res = switch (params.len) {
            0, 1 => try p.addNode(.{
                .tag = if (comma) .call_one_comma else .call_one,
                .main_token = lparen,
                .data = .{ .node_and_opt_node = .{
                    res,
                    if (params.len >= 1) .fromOptional(params[0]) else .none,
                } },
            }),
            else => try p.addNode(.{
                .tag = if (comma) .call_comma else .call,
                .main_token = lparen,
                .data = .{ .node_and_extra = .{
                    res,
                    try p.addExtra(try p.listToSpan(params)),
                } },
            }),
        };
    }
}

/// PrimaryTypeExpr
///     <- BUILTINIDENTIFIER FnCallArguments
///      / CHAR_LITERAL
///      / ContainerDecl
///      / DOT IDENTIFIER
///      / DOT InitList
///      / ErrorSetDecl
///      / FLOAT
///      / FnProto
///      / GroupedExpr
///      / LabeledTypeExpr
///      / IDENTIFIER
///      / IfTypeExpr
///      / INTEGER
///      / KEYWORD_comptime TypeExpr
///      / KEYWORD_error DOT IDENTIFIER
///      / KEYWORD_anyframe
///      / KEYWORD_unreachable
///      / STRINGLITERAL
///
/// ContainerDecl <- (KEYWORD_extern / KEYWORD_packed)? ContainerDeclAuto
///
/// ContainerDeclAuto <- ContainerDeclType LBRACE container_doc_comment? ContainerMembers RBRACE
///
/// InitList
///     <- LBRACE FieldInit (COMMA FieldInit)* COMMA? RBRACE
///      / LBRACE Expr (COMMA Expr)* COMMA? RBRACE
///      / LBRACE RBRACE
///
/// ErrorSetDecl <- KEYWORD_error LBRACE IdentifierList RBRACE
///
/// GroupedExpr <- LPAREN Expr RPAREN
///
/// IfTypeExpr <- IfPrefix TypeExpr (KEYWORD_else Payload? TypeExpr)?
///
/// LabeledTypeExpr
///     <- BlockLabel Block
///      / BlockLabel? LoopTypeExpr
///      / BlockLabel? SwitchExpr
///
/// LoopTypeExpr <- KEYWORD_inline? (ForTypeExpr / WhileTypeExpr)
fn parsePrimaryTypeExpr(p: *Parse) !?Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .char_literal => return try p.addNode(.{
            .tag = .char_literal,
            .main_token = p.nextToken(),
            .data = undefined,
        }),
        .number_literal => return try p.addNode(.{
            .tag = .number_literal,
            .main_token = p.nextToken(),
            .data = undefined,
        }),
        .keyword_unreachable => return try p.addNode(.{
            .tag = .unreachable_literal,
            .main_token = p.nextToken(),
            .data = undefined,
        }),
        .keyword_anyframe => return try p.addNode(.{
            .tag = .anyframe_literal,
            .main_token = p.nextToken(),
            .data = undefined,
        }),
        .string_literal => {
            const main_token = p.nextToken();
            return try p.addNode(.{
                .tag = .string_literal,
                .main_token = main_token,
                .data = undefined,
            });
        },

        .builtin => return try p.parseBuiltinCall(),
        .keyword_fn => return try p.parseFnProto(),
        .keyword_if => return try p.parseIf(expectTypeExpr),
        .keyword_switch => return try p.expectSwitchExpr(false),

        .keyword_extern,
        .keyword_packed,
        => {
            p.tok_i += 1;
            return try p.parseContainerDeclAuto();
        },

        .keyword_struct,
        .keyword_opaque,
        .keyword_enum,
        .keyword_union,
        => return try p.parseContainerDeclAuto(),

        .keyword_comptime => return try p.addNode(.{
            .tag = .@"comptime",
            .main_token = p.nextToken(),
            .data = .{ .node = try p.expectTypeExpr() },
        }),
        .multiline_string_literal_line => {
            const first_line = p.nextToken();
            while (p.tokenTag(p.tok_i) == .multiline_string_literal_line) {
                p.tok_i += 1;
            }
            return try p.addNode(.{
                .tag = .multiline_string_literal,
                .main_token = first_line,
                .data = .{ .token_and_token = .{
                    first_line,
                    p.tok_i - 1,
                } },
            });
        },
        .identifier => switch (p.tokenTag(p.tok_i + 1)) {
            .colon => switch (p.tokenTag(p.tok_i + 2)) {
                .keyword_inline => {
                    p.tok_i += 3;
                    switch (p.tokenTag(p.tok_i)) {
                        .keyword_for => return try p.parseFor(expectTypeExpr),
                        .keyword_while => return try p.parseWhileTypeExpr(),
                        else => return p.fail(.expected_inlinable),
                    }
                },
                .keyword_for => {
                    p.tok_i += 2;
                    return try p.parseFor(expectTypeExpr);
                },
                .keyword_while => {
                    p.tok_i += 2;
                    return try p.parseWhileTypeExpr();
                },
                .keyword_switch => {
                    p.tok_i += 2;
                    return try p.expectSwitchExpr(true);
                },
                .l_brace => {
                    p.tok_i += 2;
                    return try p.parseBlock();
                },
                else => return try p.addNode(.{
                    .tag = .identifier,
                    .main_token = p.nextToken(),
                    .data = undefined,
                }),
            },
            else => return try p.addNode(.{
                .tag = .identifier,
                .main_token = p.nextToken(),
                .data = undefined,
            }),
        },
        .keyword_inline => {
            p.tok_i += 1;
            switch (p.tokenTag(p.tok_i)) {
                .keyword_for => return try p.parseFor(expectTypeExpr),
                .keyword_while => return try p.parseWhileTypeExpr(),
                else => return p.fail(.expected_inlinable),
            }
        },
        .keyword_for => return try p.parseFor(expectTypeExpr),
        .keyword_while => return try p.parseWhileTypeExpr(),
        .period => switch (p.tokenTag(p.tok_i + 1)) {
            .identifier => {
                p.tok_i += 1;
                return try p.addNode(.{
                    .tag = .enum_literal,
                    .main_token = p.nextToken(), // identifier
                    .data = undefined,
                });
            },
            .l_brace => {
                const lbrace = p.tok_i + 1;
                p.tok_i = lbrace + 1;

                // If there are 0, 1, or 2 items, we can use ArrayInitDotTwo/StructInitDotTwo;
                // otherwise we use the full ArrayInitDot/StructInitDot.

                const scratch_top = p.scratch.items.len;
                defer p.scratch.shrinkRetainingCapacity(scratch_top);
                const opt_field_init = try p.parseFieldInit();
                if (opt_field_init) |field_init| {
                    try p.scratch.append(p.gpa, field_init);
                    while (true) {
                        switch (p.tokenTag(p.tok_i)) {
                            .comma => p.tok_i += 1,
                            .r_brace => {
                                p.tok_i += 1;
                                break;
                            },
                            .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                            // Likely just a missing comma; give error but continue parsing.
                            else => try p.warn(.expected_comma_after_initializer),
                        }
                        if (p.eatToken(.r_brace)) |_| break;
                        const next = try p.expectFieldInit();
                        try p.scratch.append(p.gpa, next);
                    }
                    const comma = (p.tokenTag(p.tok_i - 2)) == .comma;
                    const inits = p.scratch.items[scratch_top..];
                    std.debug.assert(inits.len != 0);
                    if (inits.len <= 2) {
                        return try p.addNode(.{
                            .tag = if (comma) .struct_init_dot_two_comma else .struct_init_dot_two,
                            .main_token = lbrace,
                            .data = .{ .opt_node_and_opt_node = .{
                                if (inits.len >= 1) .fromOptional(inits[0]) else .none,
                                if (inits.len >= 2) .fromOptional(inits[1]) else .none,
                            } },
                        });
                    } else {
                        return try p.addNode(.{
                            .tag = if (comma) .struct_init_dot_comma else .struct_init_dot,
                            .main_token = lbrace,
                            .data = .{ .extra_range = try p.listToSpan(inits) },
                        });
                    }
                }

                while (true) {
                    if (p.eatToken(.r_brace)) |_| break;
                    const elem_init = try p.expectExpr();
                    try p.scratch.append(p.gpa, elem_init);
                    switch (p.tokenTag(p.tok_i)) {
                        .comma => p.tok_i += 1,
                        .r_brace => {
                            p.tok_i += 1;
                            break;
                        },
                        .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                        // Likely just a missing comma; give error but continue parsing.
                        else => try p.warn(.expected_comma_after_initializer),
                    }
                }
                const comma = (p.tokenTag(p.tok_i - 2)) == .comma;
                const inits = p.scratch.items[scratch_top..];
                if (inits.len <= 2) {
                    return try p.addNode(.{
                        .tag = if (inits.len == 0)
                            .struct_init_dot_two
                        else if (comma) .array_init_dot_two_comma else .array_init_dot_two,
                        .main_token = lbrace,
                        .data = .{ .opt_node_and_opt_node = .{
                            if (inits.len >= 1) inits[0].toOptional() else .none,
                            if (inits.len >= 2) inits[1].toOptional() else .none,
                        } },
                    });
                } else {
                    return try p.addNode(.{
                        .tag = if (comma) .array_init_dot_comma else .array_init_dot,
                        .main_token = lbrace,
                        .data = .{ .extra_range = try p.listToSpan(inits) },
                    });
                }
            },
            else => return null,
        },
        .keyword_error => switch (p.tokenTag(p.tok_i + 1)) {
            .l_brace => {
                const error_token = p.tok_i;
                p.tok_i += 2;
                while (true) {
                    if (p.eatToken(.r_brace)) |_| break;
                    _ = try p.eatDocComments();
                    _ = try p.expectToken(.identifier);
                    switch (p.tokenTag(p.tok_i)) {
                        .comma => p.tok_i += 1,
                        .r_brace => {
                            p.tok_i += 1;
                            break;
                        },
                        .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                        // Likely just a missing comma; give error but continue parsing.
                        else => try p.warn(.expected_comma_after_field),
                    }
                }
                return try p.addNode(.{
                    .tag = .error_set_decl,
                    .main_token = error_token,
                    .data = .{
                        .token_and_token = .{
                            error_token + 1, // lbrace
                            p.tok_i - 1, // rbrace
                        },
                    },
                });
            },
            else => {
                const main_token = p.nextToken();
                const period = p.eatToken(.period);
                if (period == null) return p.failExpected(.period);
                const identifier = p.eatToken(.identifier);
                if (identifier == null) return p.failExpected(.identifier);
                return try p.addNode(.{
                    .tag = .error_value,
                    .main_token = main_token,
                    .data = undefined,
                });
            },
        },
        .l_paren => return try p.addNode(.{
            .tag = .grouped_expression,
            .main_token = p.nextToken(),
            .data = .{ .node_and_token = .{
                try p.expectExpr(),
                try p.expectToken(.r_paren),
            } },
        }),
        else => return null,
    }
}

fn expectPrimaryTypeExpr(p: *Parse) !Node.Index {
    return try p.parsePrimaryTypeExpr() orelse return p.fail(.expected_primary_type_expr);
}

/// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
///
/// WhileTypeExpr <- WhilePrefix TypeExpr (KEYWORD_else Payload? TypeExpr)?
fn parseWhileTypeExpr(p: *Parse) !?Node.Index {
    const while_token = p.eatToken(.keyword_while) orelse return null;
    _ = try p.expectToken(.l_paren);
    const condition = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    _ = try p.parsePtrPayload();
    const cont_expr = try p.parseWhileContinueExpr();

    const then_expr = try p.expectTypeExpr();
    _ = p.eatToken(.keyword_else) orelse {
        if (cont_expr == null) {
            return try p.addNode(.{
                .tag = .while_simple,
                .main_token = while_token,
                .data = .{ .node_and_node = .{
                    condition,
                    then_expr,
                } },
            });
        } else {
            return try p.addNode(.{
                .tag = .while_cont,
                .main_token = while_token,
                .data = .{ .node_and_extra = .{
                    condition, try p.addExtra(Node.WhileCont{
                        .cont_expr = cont_expr.?,
                        .then_expr = then_expr,
                    }),
                } },
            });
        }
    };
    _ = try p.parsePayload();
    const else_expr = try p.expectTypeExpr();
    return try p.addNode(.{
        .tag = .@"while",
        .main_token = while_token,
        .data = .{ .node_and_extra = .{
            condition, try p.addExtra(Node.While{
                .cont_expr = .fromOptional(cont_expr),
                .then_expr = then_expr,
                .else_expr = else_expr,
            }),
        } },
    });
}

/// SwitchExpr <- KEYWORD_switch LPAREN Expr RPAREN LBRACE SwitchProngList RBRACE
fn parseSwitchExpr(p: *Parse, is_labeled: bool) !?Node.Index {
    const switch_token = p.eatToken(.keyword_switch) orelse return null;
    return try p.expectSwitchSuffix(if (is_labeled) switch_token - 2 else switch_token);
}

fn expectSwitchExpr(p: *Parse, is_labeled: bool) !Node.Index {
    const switch_token = p.assertToken(.keyword_switch);
    return try p.expectSwitchSuffix(if (is_labeled) switch_token - 2 else switch_token);
}

fn expectSwitchSuffix(p: *Parse, main_token: TokenIndex) !Node.Index {
    _ = try p.expectToken(.l_paren);
    const expr_node = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    _ = try p.expectToken(.l_brace);
    const cases = try p.parseSwitchProngList();
    const trailing_comma = p.tokenTag(p.tok_i - 1) == .comma;
    _ = try p.expectToken(.r_brace);

    return p.addNode(.{
        .tag = if (trailing_comma) .switch_comma else .@"switch",
        .main_token = main_token,
        .data = .{ .node_and_extra = .{
            expr_node,
            try p.addExtra(Node.SubRange{
                .start = cases.start,
                .end = cases.end,
            }),
        } },
    });
}

/// AsmExpr <- KEYWORD_asm KEYWORD_volatile? LPAREN Expr AsmOutput? RPAREN
///
/// AsmOutput <- COLON AsmOutputList AsmInput?
///
/// AsmInput <- COLON AsmInputList AsmClobbers?
///
/// AsmClobbers <- COLON StringList
///
/// StringList <- (STRINGLITERAL COMMA)* STRINGLITERAL?
///
/// AsmOutputList <- (AsmOutputItem COMMA)* AsmOutputItem?
///
/// AsmInputList <- (AsmInputItem COMMA)* AsmInputItem?
fn expectAsmExpr(p: *Parse) !Node.Index {
    const asm_token = p.assertToken(.keyword_asm);
    _ = p.eatToken(.keyword_volatile);
    _ = try p.expectToken(.l_paren);
    const template = try p.expectExpr();

    if (p.eatToken(.r_paren)) |rparen| {
        return p.addNode(.{
            .tag = .asm_simple,
            .main_token = asm_token,
            .data = .{ .node_and_token = .{
                template,
                rparen,
            } },
        });
    }

    _ = try p.expectToken(.colon);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        const output_item = try p.parseAsmOutputItem() orelse break;
        try p.scratch.append(p.gpa, output_item);
        switch (p.tokenTag(p.tok_i)) {
            .comma => p.tok_i += 1,
            // All possible delimiters.
            .colon, .r_paren, .r_brace, .r_bracket => break,
            // Likely just a missing comma; give error but continue parsing.
            else => try p.warnExpected(.comma),
        }
    }
    if (p.eatToken(.colon)) |_| {
        while (true) {
            const input_item = try p.parseAsmInputItem() orelse break;
            try p.scratch.append(p.gpa, input_item);
            switch (p.tokenTag(p.tok_i)) {
                .comma => p.tok_i += 1,
                // All possible delimiters.
                .colon, .r_paren, .r_brace, .r_bracket => break,
                // Likely just a missing comma; give error but continue parsing.
                else => try p.warnExpected(.comma),
            }
        }
        if (p.eatToken(.colon)) |_| {
            while (p.eatToken(.string_literal)) |_| {
                switch (p.tokenTag(p.tok_i)) {
                    .comma => p.tok_i += 1,
                    .colon, .r_paren, .r_brace, .r_bracket => break,
                    // Likely just a missing comma; give error but continue parsing.
                    else => try p.warnExpected(.comma),
                }
            }
        }
    }
    const rparen = try p.expectToken(.r_paren);
    const span = try p.listToSpan(p.scratch.items[scratch_top..]);
    return p.addNode(.{
        .tag = .@"asm",
        .main_token = asm_token,
        .data = .{ .node_and_extra = .{
            template,
            try p.addExtra(Node.Asm{
                .items_start = span.start,
                .items_end = span.end,
                .rparen = rparen,
            }),
        } },
    });
}

/// AsmOutputItem <- LBRACKET IDENTIFIER RBRACKET STRINGLITERAL LPAREN (MINUSRARROW TypeExpr / IDENTIFIER) RPAREN
fn parseAsmOutputItem(p: *Parse) !?Node.Index {
    _ = p.eatToken(.l_bracket) orelse return null;
    const identifier = try p.expectToken(.identifier);
    _ = try p.expectToken(.r_bracket);
    _ = try p.expectToken(.string_literal);
    _ = try p.expectToken(.l_paren);
    const type_expr: Node.OptionalIndex = blk: {
        if (p.eatToken(.arrow)) |_| {
            break :blk .fromOptional(try p.expectTypeExpr());
        } else {
            _ = try p.expectToken(.identifier);
            break :blk .none;
        }
    };
    const rparen = try p.expectToken(.r_paren);
    return try p.addNode(.{
        .tag = .asm_output,
        .main_token = identifier,
        .data = .{ .opt_node_and_token = .{
            type_expr,
            rparen,
        } },
    });
}

/// AsmInputItem <- LBRACKET IDENTIFIER RBRACKET STRINGLITERAL LPAREN Expr RPAREN
fn parseAsmInputItem(p: *Parse) !?Node.Index {
    _ = p.eatToken(.l_bracket) orelse return null;
    const identifier = try p.expectToken(.identifier);
    _ = try p.expectToken(.r_bracket);
    _ = try p.expectToken(.string_literal);
    _ = try p.expectToken(.l_paren);
    const expr = try p.expectExpr();
    const rparen = try p.expectToken(.r_paren);
    return try p.addNode(.{
        .tag = .asm_input,
        .main_token = identifier,
        .data = .{ .node_and_token = .{
            expr,
            rparen,
        } },
    });
}

/// BreakLabel <- COLON IDENTIFIER
fn parseBreakLabel(p: *Parse) Error!OptionalTokenIndex {
    _ = p.eatToken(.colon) orelse return .none;
    const next_token = try p.expectToken(.identifier);
    return .fromToken(next_token);
}

/// BlockLabel <- IDENTIFIER COLON
fn parseBlockLabel(p: *Parse) ?TokenIndex {
    return p.eatTokens(&.{ .identifier, .colon });
}

/// FieldInit <- DOT IDENTIFIER EQUAL Expr
fn parseFieldInit(p: *Parse) !?Node.Index {
    if (p.eatTokens(&.{ .period, .identifier, .equal })) |_| {
        return try p.expectExpr();
    }
    return null;
}

fn expectFieldInit(p: *Parse) !Node.Index {
    if (p.eatTokens(&.{ .period, .identifier, .equal })) |_| {
        return try p.expectExpr();
    }
    return p.fail(.expected_initializer);
}

/// WhileContinueExpr <- COLON LPAREN AssignExpr RPAREN
fn parseWhileContinueExpr(p: *Parse) !?Node.Index {
    _ = p.eatToken(.colon) orelse {
        if (p.tokenTag(p.tok_i) == .l_paren and
            p.tokensOnSameLine(p.tok_i - 1, p.tok_i))
            return p.fail(.expected_continue_expr);
        return null;
    };
    _ = try p.expectToken(.l_paren);
    const node = try p.parseAssignExpr() orelse return p.fail(.expected_expr_or_assignment);
    _ = try p.expectToken(.r_paren);
    return node;
}

/// LinkSection <- KEYWORD_linksection LPAREN Expr RPAREN
fn parseLinkSection(p: *Parse) !?Node.Index {
    _ = p.eatToken(.keyword_linksection) orelse return null;
    _ = try p.expectToken(.l_paren);
    const expr_node = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    return expr_node;
}

/// CallConv <- KEYWORD_callconv LPAREN Expr RPAREN
fn parseCallconv(p: *Parse) !?Node.Index {
    _ = p.eatToken(.keyword_callconv) orelse return null;
    _ = try p.expectToken(.l_paren);
    const expr_node = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    return expr_node;
}

/// AddrSpace <- KEYWORD_addrspace LPAREN Expr RPAREN
fn parseAddrSpace(p: *Parse) !?Node.Index {
    _ = p.eatToken(.keyword_addrspace) orelse return null;
    _ = try p.expectToken(.l_paren);
    const expr_node = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    return expr_node;
}

/// This function can return null nodes and then still return nodes afterwards,
/// such as in the case of anytype and `...`. Caller must look for rparen to find
/// out when there are no more param decls left.
///
/// ParamDecl
///     <- doc_comment? (KEYWORD_noalias / KEYWORD_comptime)? (IDENTIFIER COLON)? ParamType
///      / DOT3
///
/// ParamType
///     <- KEYWORD_anytype
///      / TypeExpr
fn expectParamDecl(p: *Parse) !?Node.Index {
    _ = try p.eatDocComments();
    switch (p.tokenTag(p.tok_i)) {
        .keyword_noalias, .keyword_comptime => p.tok_i += 1,
        .ellipsis3 => {
            p.tok_i += 1;
            return null;
        },
        else => {},
    }
    _ = p.eatTokens(&.{ .identifier, .colon });
    if (p.eatToken(.keyword_anytype)) |_| {
        return null;
    } else {
        return try p.expectTypeExpr();
    }
}

/// Payload <- PIPE IDENTIFIER PIPE
fn parsePayload(p: *Parse) Error!OptionalTokenIndex {
    _ = p.eatToken(.pipe) orelse return .none;
    const identifier = try p.expectToken(.identifier);
    _ = try p.expectToken(.pipe);
    return .fromToken(identifier);
}

/// PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
fn parsePtrPayload(p: *Parse) Error!OptionalTokenIndex {
    _ = p.eatToken(.pipe) orelse return .none;
    _ = p.eatToken(.asterisk);
    const identifier = try p.expectToken(.identifier);
    _ = try p.expectToken(.pipe);
    return .fromToken(identifier);
}

/// Returns the first identifier token, if any.
///
/// PtrIndexPayload <- PIPE ASTERISK? IDENTIFIER (COMMA IDENTIFIER)? PIPE
fn parsePtrIndexPayload(p: *Parse) Error!OptionalTokenIndex {
    _ = p.eatToken(.pipe) orelse return .none;
    _ = p.eatToken(.asterisk);
    const identifier = try p.expectToken(.identifier);
    if (p.eatToken(.comma) != null) {
        _ = try p.expectToken(.identifier);
    }
    _ = try p.expectToken(.pipe);
    return .fromToken(identifier);
}

/// SwitchProng <- KEYWORD_inline? SwitchCase EQUALRARROW PtrIndexPayload? AssignExpr
///
/// SwitchCase
///     <- SwitchItem (COMMA SwitchItem)* COMMA?
///      / KEYWORD_else
fn parseSwitchProng(p: *Parse) !?Node.Index {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    const is_inline = p.eatToken(.keyword_inline) != null;

    if (p.eatToken(.keyword_else) == null) {
        while (true) {
            const item = try p.parseSwitchItem() orelse break;
            try p.scratch.append(p.gpa, item);
            if (p.eatToken(.comma) == null) break;
        }
        if (scratch_top == p.scratch.items.len) {
            if (is_inline) p.tok_i -= 1;
            return null;
        }
    }
    const arrow_token = try p.expectToken(.equal_angle_bracket_right);
    _ = try p.parsePtrIndexPayload();

    const items = p.scratch.items[scratch_top..];
    if (items.len <= 1) {
        return try p.addNode(.{
            .tag = if (is_inline) .switch_case_inline_one else .switch_case_one,
            .main_token = arrow_token,
            .data = .{ .opt_node_and_node = .{
                if (items.len >= 1) items[0].toOptional() else .none,
                try p.expectSingleAssignExpr(),
            } },
        });
    } else {
        return try p.addNode(.{
            .tag = if (is_inline) .switch_case_inline else .switch_case,
            .main_token = arrow_token,
            .data = .{ .extra_and_node = .{
                try p.addExtra(try p.listToSpan(items)),
                try p.expectSingleAssignExpr(),
            } },
        });
    }
}

/// SwitchItem <- Expr (DOT3 Expr)?
fn parseSwitchItem(p: *Parse) !?Node.Index {
    const expr = try p.parseExpr() orelse return null;

    if (p.eatToken(.ellipsis3)) |token| {
        return try p.addNode(.{
            .tag = .switch_range,
            .main_token = token,
            .data = .{ .node_and_node = .{
                expr,
                try p.expectExpr(),
            } },
        });
    }
    return expr;
}

/// The following invariant will hold:
/// - `(bit_range_start == .none) == (bit_range_end == .none)`
/// - `bit_range_start != .none` implies `align_node != .none`
/// - `bit_range_end != .none` implies `align_node != .none`
const PtrModifiers = struct {
    align_node: Node.OptionalIndex,
    addrspace_node: Node.OptionalIndex,
    bit_range_start: Node.OptionalIndex,
    bit_range_end: Node.OptionalIndex,
};

fn parsePtrModifiers(p: *Parse) !PtrModifiers {
    var result: PtrModifiers = .{
        .align_node = .none,
        .addrspace_node = .none,
        .bit_range_start = .none,
        .bit_range_end = .none,
    };
    var saw_const = false;
    var saw_volatile = false;
    var saw_allowzero = false;
    while (true) {
        switch (p.tokenTag(p.tok_i)) {
            .keyword_align => {
                if (result.align_node != .none) {
                    try p.warn(.extra_align_qualifier);
                }
                p.tok_i += 1;
                _ = try p.expectToken(.l_paren);
                result.align_node = (try p.expectExpr()).toOptional();

                if (p.eatToken(.colon)) |_| {
                    result.bit_range_start = (try p.expectExpr()).toOptional();
                    _ = try p.expectToken(.colon);
                    result.bit_range_end = (try p.expectExpr()).toOptional();
                }

                _ = try p.expectToken(.r_paren);
            },
            .keyword_const => {
                if (saw_const) {
                    try p.warn(.extra_const_qualifier);
                }
                p.tok_i += 1;
                saw_const = true;
            },
            .keyword_volatile => {
                if (saw_volatile) {
                    try p.warn(.extra_volatile_qualifier);
                }
                p.tok_i += 1;
                saw_volatile = true;
            },
            .keyword_allowzero => {
                if (saw_allowzero) {
                    try p.warn(.extra_allowzero_qualifier);
                }
                p.tok_i += 1;
                saw_allowzero = true;
            },
            .keyword_addrspace => {
                if (result.addrspace_node != .none) {
                    try p.warn(.extra_addrspace_qualifier);
                }
                result.addrspace_node = .fromOptional(try p.parseAddrSpace());
            },
            else => return result,
        }
    }
}

/// SuffixOp
///     <- LBRACKET Expr (DOT2 (Expr? (COLON Expr)?)?)? RBRACKET
///      / DOT IDENTIFIER
///      / DOTASTERISK
///      / DOTQUESTIONMARK
fn parseSuffixOp(p: *Parse, lhs: Node.Index) !?Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .l_bracket => {
            const lbracket = p.nextToken();
            const index_expr = try p.expectExpr();

            if (p.eatToken(.ellipsis2)) |_| {
                const opt_end_expr = try p.parseExpr();
                if (p.eatToken(.colon)) |_| {
                    const sentinel = try p.expectExpr();
                    _ = try p.expectToken(.r_bracket);
                    return try p.addNode(.{
                        .tag = .slice_sentinel,
                        .main_token = lbracket,
                        .data = .{ .node_and_extra = .{
                            lhs, try p.addExtra(Node.SliceSentinel{
                                .start = index_expr,
                                .end = .fromOptional(opt_end_expr),
                                .sentinel = sentinel,
                            }),
                        } },
                    });
                }
                _ = try p.expectToken(.r_bracket);
                const end_expr = opt_end_expr orelse {
                    return try p.addNode(.{
                        .tag = .slice_open,
                        .main_token = lbracket,
                        .data = .{ .node_and_node = .{
                            lhs,
                            index_expr,
                        } },
                    });
                };
                return try p.addNode(.{
                    .tag = .slice,
                    .main_token = lbracket,
                    .data = .{ .node_and_extra = .{
                        lhs, try p.addExtra(Node.Slice{
                            .start = index_expr,
                            .end = end_expr,
                        }),
                    } },
                });
            }
            _ = try p.expectToken(.r_bracket);
            return try p.addNode(.{
                .tag = .array_access,
                .main_token = lbracket,
                .data = .{ .node_and_node = .{
                    lhs,
                    index_expr,
                } },
            });
        },
        .period_asterisk => return try p.addNode(.{
            .tag = .deref,
            .main_token = p.nextToken(),
            .data = .{ .node = lhs },
        }),
        .invalid_periodasterisks => {
            try p.warn(.asterisk_after_ptr_deref);
            return try p.addNode(.{
                .tag = .deref,
                .main_token = p.nextToken(),
                .data = .{ .node = lhs },
            });
        },
        .period => switch (p.tokenTag(p.tok_i + 1)) {
            .identifier => return try p.addNode(.{
                .tag = .field_access,
                .main_token = p.nextToken(),
                .data = .{ .node_and_token = .{
                    lhs,
                    p.nextToken(),
                } },
            }),
            .question_mark => return try p.addNode(.{
                .tag = .unwrap_optional,
                .main_token = p.nextToken(),
                .data = .{ .node_and_token = .{
                    lhs,
                    p.nextToken(),
                } },
            }),
            .l_brace => {
                // this a misplaced `.{`, handle the error somewhere else
                return null;
            },
            else => {
                p.tok_i += 1;
                try p.warn(.expected_suffix_op);
                return null;
            },
        },
        else => return null,
    }
}

/// Caller must have already verified the first token.
///
/// ContainerDeclAuto <- ContainerDeclType LBRACE container_doc_comment? ContainerMembers RBRACE
///
/// ContainerDeclType
///     <- KEYWORD_struct (LPAREN Expr RPAREN)?
///      / KEYWORD_opaque
///      / KEYWORD_enum (LPAREN Expr RPAREN)?
///      / KEYWORD_union (LPAREN (KEYWORD_enum (LPAREN Expr RPAREN)? / Expr) RPAREN)?
fn parseContainerDeclAuto(p: *Parse) !?Node.Index {
    const main_token = p.nextToken();
    const arg_expr = switch (p.tokenTag(main_token)) {
        .keyword_opaque => null,
        .keyword_struct, .keyword_enum => blk: {
            if (p.eatToken(.l_paren)) |_| {
                const expr = try p.expectExpr();
                _ = try p.expectToken(.r_paren);
                break :blk expr;
            } else {
                break :blk null;
            }
        },
        .keyword_union => blk: {
            if (p.eatToken(.l_paren)) |_| {
                if (p.eatToken(.keyword_enum)) |_| {
                    if (p.eatToken(.l_paren)) |_| {
                        const enum_tag_expr = try p.expectExpr();
                        _ = try p.expectToken(.r_paren);
                        _ = try p.expectToken(.r_paren);

                        _ = try p.expectToken(.l_brace);
                        const members = try p.parseContainerMembers();
                        const members_span = try members.toSpan(p);
                        _ = try p.expectToken(.r_brace);
                        return try p.addNode(.{
                            .tag = switch (members.trailing) {
                                true => .tagged_union_enum_tag_trailing,
                                false => .tagged_union_enum_tag,
                            },
                            .main_token = main_token,
                            .data = .{ .node_and_extra = .{
                                enum_tag_expr,
                                try p.addExtra(members_span),
                            } },
                        });
                    } else {
                        _ = try p.expectToken(.r_paren);

                        _ = try p.expectToken(.l_brace);
                        const members = try p.parseContainerMembers();
                        _ = try p.expectToken(.r_brace);
                        if (members.len <= 2) {
                            return try p.addNode(.{
                                .tag = switch (members.trailing) {
                                    true => .tagged_union_two_trailing,
                                    false => .tagged_union_two,
                                },
                                .main_token = main_token,
                                .data = members.data,
                            });
                        } else {
                            const span = try members.toSpan(p);
                            return try p.addNode(.{
                                .tag = switch (members.trailing) {
                                    true => .tagged_union_trailing,
                                    false => .tagged_union,
                                },
                                .main_token = main_token,
                                .data = .{ .extra_range = span },
                            });
                        }
                    }
                } else {
                    const expr = try p.expectExpr();
                    _ = try p.expectToken(.r_paren);
                    break :blk expr;
                }
            } else {
                break :blk null;
            }
        },
        else => {
            p.tok_i -= 1;
            return p.fail(.expected_container);
        },
    };
    _ = try p.expectToken(.l_brace);
    const members = try p.parseContainerMembers();
    _ = try p.expectToken(.r_brace);
    if (arg_expr == null) {
        if (members.len <= 2) {
            return try p.addNode(.{
                .tag = switch (members.trailing) {
                    true => .container_decl_two_trailing,
                    false => .container_decl_two,
                },
                .main_token = main_token,
                .data = members.data,
            });
        } else {
            const span = try members.toSpan(p);
            return try p.addNode(.{
                .tag = switch (members.trailing) {
                    true => .container_decl_trailing,
                    false => .container_decl,
                },
                .main_token = main_token,
                .data = .{ .extra_range = span },
            });
        }
    } else {
        const span = try members.toSpan(p);
        return try p.addNode(.{
            .tag = switch (members.trailing) {
                true => .container_decl_arg_trailing,
                false => .container_decl_arg,
            },
            .main_token = main_token,
            .data = .{ .node_and_extra = .{
                arg_expr.?,
                try p.addExtra(Node.SubRange{
                    .start = span.start,
                    .end = span.end,
                }),
            } },
        });
    }
}

/// Give a helpful error message for those transitioning from
/// C's 'struct Foo {};' to Zig's 'const Foo = struct {};'.
fn parseCStyleContainer(p: *Parse) Error!bool {
    const main_token = p.tok_i;
    switch (p.tokenTag(p.tok_i)) {
        .keyword_enum, .keyword_union, .keyword_struct => {},
        else => return false,
    }
    const identifier = p.tok_i + 1;
    if (p.tokenTag(identifier) != .identifier) return false;
    p.tok_i += 2;

    try p.warnMsg(.{
        .tag = .c_style_container,
        .token = identifier,
        .extra = .{ .expected_tag = p.tokenTag(main_token) },
    });
    try p.warnMsg(.{
        .tag = .zig_style_container,
        .is_note = true,
        .token = identifier,
        .extra = .{ .expected_tag = p.tokenTag(main_token) },
    });

    _ = try p.expectToken(.l_brace);
    _ = try p.parseContainerMembers();
    _ = try p.expectToken(.r_brace);
    try p.expectSemicolon(.expected_semi_after_decl, true);
    return true;
}

/// Holds temporary data until we are ready to construct the full ContainerDecl AST node.
///
/// ByteAlign <- KEYWORD_align LPAREN Expr RPAREN
fn parseByteAlign(p: *Parse) !?Node.Index {
    _ = p.eatToken(.keyword_align) orelse return null;
    _ = try p.expectToken(.l_paren);
    const expr = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    return expr;
}

/// SwitchProngList <- (SwitchProng COMMA)* SwitchProng?
fn parseSwitchProngList(p: *Parse) !Node.SubRange {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        const item = try parseSwitchProng(p) orelse break;

        try p.scratch.append(p.gpa, item);

        switch (p.tokenTag(p.tok_i)) {
            .comma => p.tok_i += 1,
            // All possible delimiters.
            .colon, .r_paren, .r_brace, .r_bracket => break,
            // Likely just a missing comma; give error but continue parsing.
            else => try p.warn(.expected_comma_after_switch_prong),
        }
    }
    return p.listToSpan(p.scratch.items[scratch_top..]);
}

/// ParamDeclList <- (ParamDecl COMMA)* ParamDecl?
fn parseParamDeclList(p: *Parse) !SmallSpan {
    _ = try p.expectToken(.l_paren);
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    var varargs: union(enum) { none, seen, nonfinal: TokenIndex } = .none;
    while (true) {
        if (p.eatToken(.r_paren)) |_| break;
        if (varargs == .seen) varargs = .{ .nonfinal = p.tok_i };
        const opt_param = try p.expectParamDecl();
        if (opt_param) |param| {
            try p.scratch.append(p.gpa, param);
        } else if (p.tokenTag(p.tok_i - 1) == .ellipsis3) {
            if (varargs == .none) varargs = .seen;
        }
        switch (p.tokenTag(p.tok_i)) {
            .comma => p.tok_i += 1,
            .r_paren => {
                p.tok_i += 1;
                break;
            },
            .colon, .r_brace, .r_bracket => return p.failExpected(.r_paren),
            // Likely just a missing comma; give error but continue parsing.
            else => try p.warn(.expected_comma_after_param),
        }
    }
    if (varargs == .nonfinal) {
        try p.warnMsg(.{ .tag = .varargs_nonfinal, .token = varargs.nonfinal });
    }
    const params = p.scratch.items[scratch_top..];
    return switch (params.len) {
        0 => .{ .zero_or_one = .none },
        1 => .{ .zero_or_one = params[0].toOptional() },
        else => .{ .multi = try p.listToSpan(params) },
    };
}

/// FnCallArguments <- LPAREN ExprList RPAREN
///
/// ExprList <- (Expr COMMA)* Expr?
fn parseBuiltinCall(p: *Parse) !Node.Index {
    const builtin_token = p.assertToken(.builtin);
    _ = p.eatToken(.l_paren) orelse {
        try p.warn(.expected_param_list);
        // Pretend this was an identifier so we can continue parsing.
        return p.addNode(.{
            .tag = .identifier,
            .main_token = builtin_token,
            .data = undefined,
        });
    };
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    while (true) {
        if (p.eatToken(.r_paren)) |_| break;
        const param = try p.expectExpr();
        try p.scratch.append(p.gpa, param);
        switch (p.tokenTag(p.tok_i)) {
            .comma => p.tok_i += 1,
            .r_paren => {
                p.tok_i += 1;
                break;
            },
            // Likely just a missing comma; give error but continue parsing.
            else => try p.warn(.expected_comma_after_arg),
        }
    }
    const comma = (p.tokenTag(p.tok_i - 2)) == .comma;
    const params = p.scratch.items[scratch_top..];
    if (params.len <= 2) {
        return p.addNode(.{
            .tag = if (comma) .builtin_call_two_comma else .builtin_call_two,
            .main_token = builtin_token,
            .data = .{ .opt_node_and_opt_node = .{
                if (params.len >= 1) .fromOptional(params[0]) else .none,
                if (params.len >= 2) .fromOptional(params[1]) else .none,
            } },
        });
    } else {
        const span = try p.listToSpan(params);
        return p.addNode(.{
            .tag = if (comma) .builtin_call_comma else .builtin_call,
            .main_token = builtin_token,
            .data = .{ .extra_range = span },
        });
    }
}

/// IfPrefix <- KEYWORD_if LPAREN Expr RPAREN PtrPayload?
fn parseIf(p: *Parse, comptime bodyParseFn: fn (p: *Parse) Error!Node.Index) !?Node.Index {
    const if_token = p.eatToken(.keyword_if) orelse return null;
    _ = try p.expectToken(.l_paren);
    const condition = try p.expectExpr();
    _ = try p.expectToken(.r_paren);
    _ = try p.parsePtrPayload();

    const then_expr = try bodyParseFn(p);

    _ = p.eatToken(.keyword_else) orelse return try p.addNode(.{
        .tag = .if_simple,
        .main_token = if_token,
        .data = .{ .node_and_node = .{
            condition,
            then_expr,
        } },
    });
    _ = try p.parsePayload();
    const else_expr = try bodyParseFn(p);

    return try p.addNode(.{
        .tag = .@"if",
        .main_token = if_token,
        .data = .{ .node_and_extra = .{
            condition,
            try p.addExtra(Node.If{
                .then_expr = then_expr,
                .else_expr = else_expr,
            }),
        } },
    });
}

/// ForExpr <- ForPrefix Expr (KEYWORD_else Expr)?
///
/// ForTypeExpr <- ForPrefix TypeExpr (KEYWORD_else TypeExpr)?
fn parseFor(p: *Parse, comptime bodyParseFn: fn (p: *Parse) Error!Node.Index) !?Node.Index {
    const for_token = p.eatToken(.keyword_for) orelse return null;

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    const inputs = try p.forPrefix();

    const then_expr = try bodyParseFn(p);
    var has_else = false;
    if (p.eatToken(.keyword_else)) |_| {
        try p.scratch.append(p.gpa, then_expr);
        const else_expr = try bodyParseFn(p);
        try p.scratch.append(p.gpa, else_expr);
        has_else = true;
    } else if (inputs == 1) {
        return try p.addNode(.{
            .tag = .for_simple,
            .main_token = for_token,
            .data = .{ .node_and_node = .{
                p.scratch.items[scratch_top],
                then_expr,
            } },
        });
    } else {
        try p.scratch.append(p.gpa, then_expr);
    }
    return try p.addNode(.{
        .tag = .@"for",
        .main_token = for_token,
        .data = .{ .@"for" = .{
            (try p.listToSpan(p.scratch.items[scratch_top..])).start,
            .{ .inputs = @intCast(inputs), .has_else = has_else },
        } },
    });
}

/// Skips over doc comment tokens. Returns the first one, if any.
fn eatDocComments(p: *Parse) Allocator.Error!?TokenIndex {
    if (p.eatToken(.doc_comment)) |tok| {
        var first_line = tok;
        if (tok > 0 and tokensOnSameLine(p, tok - 1, tok)) {
            try p.warnMsg(.{
                .tag = .same_line_doc_comment,
                .token = tok,
            });
            first_line = p.eatToken(.doc_comment) orelse return null;
        }
        while (p.eatToken(.doc_comment)) |_| {}
        return first_line;
    }
    return null;
}

fn tokensOnSameLine(p: *Parse, token1: TokenIndex, token2: TokenIndex) bool {
    return std.mem.indexOfScalar(u8, p.source[p.tokenStart(token1)..p.tokenStart(token2)], '\n') == null;
}

fn eatToken(p: *Parse, tag: Token.Tag) ?TokenIndex {
    return if (p.tokenTag(p.tok_i) == tag) p.nextToken() else null;
}

fn eatTokens(p: *Parse, tags: []const Token.Tag) ?TokenIndex {
    const available_tags = p.tokens.items(.tag)[p.tok_i..];
    if (!std.mem.startsWith(Token.Tag, available_tags, tags)) return null;
    const result = p.tok_i;
    p.tok_i += @intCast(tags.len);
    return result;
}

fn assertToken(p: *Parse, tag: Token.Tag) TokenIndex {
    const token = p.nextToken();
    assert(p.tokenTag(token) == tag);
    return token;
}

fn expectToken(p: *Parse, tag: Token.Tag) Error!TokenIndex {
    if (p.tokenTag(p.tok_i) != tag) {
        return p.failMsg(.{
            .tag = .expected_token,
            .token = p.tok_i,
            .extra = .{ .expected_tag = tag },
        });
    }
    return p.nextToken();
}

fn expectSemicolon(p: *Parse, error_tag: AstError.Tag, recoverable: bool) Error!void {
    if (p.tokenTag(p.tok_i) == .semicolon) {
        _ = p.nextToken();
        return;
    }
    try p.warn(error_tag);
    if (!recoverable) return error.ParseError;
}

fn nextToken(p: *Parse) TokenIndex {
    const result = p.tok_i;
    p.tok_i += 1;
    return result;
}

const Parse = @This();
const std = @import("../std.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const AstError = Ast.Error;
const TokenIndex = Ast.TokenIndex;
const OptionalTokenIndex = Ast.OptionalTokenIndex;
const ExtraIndex = Ast.ExtraIndex;
const Token = std.zig.Token;

test {
    _ = @import("parser_test.zig");
}
