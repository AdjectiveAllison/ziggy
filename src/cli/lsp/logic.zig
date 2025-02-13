const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("../lsp.zig").Handler;
const Document = @import("Document.zig");
const Schema = @import("Schema.zig");

pub const Language = enum { ziggy, ziggy_schema };
pub const File = union(Language) {
    ziggy: Document,
    ziggy_schema: Schema,

    pub fn deinit(f: *File) void {
        switch (f.*) {
            inline else => |*x| x.deinit(),
        }
    }
};

const log = std.log.scoped(.ziggy_lsp);

pub fn loadFile(
    self: *Handler,
    arena: std.mem.Allocator,
    new_text: [:0]const u8,
    uri: []const u8,
    language: Language,
) !void {
    var res: lsp.types.PublishDiagnosticsParams = .{
        .uri = uri,
        .diagnostics = &.{},
    };

    switch (language) {
        .ziggy_schema => {
            var sk = Schema.init(self.gpa, new_text);
            errdefer sk.deinit();

            const gop = try self.files.getOrPut(self.gpa, uri);
            errdefer _ = self.files.remove(uri);

            if (gop.found_existing) {
                gop.value_ptr.deinit();
            } else {
                gop.key_ptr.* = try self.gpa.dupe(u8, uri);
            }

            gop.value_ptr.* = .{ .ziggy_schema = sk };

            switch (sk.diagnostic.err) {
                .none => {},
                else => {
                    const msg = try std.fmt.allocPrint(arena, "{lsp}", .{sk.diagnostic});
                    const sel = sk.diagnostic.tok.loc.getSelection(sk.bytes);
                    res.diagnostics = &.{
                        .{
                            .range = .{
                                .start = .{
                                    .line = sel.start.line - 1,
                                    .character = sel.start.col - 1,
                                },
                                .end = .{
                                    .line = sel.end.line - 1,
                                    .character = sel.end.col - 1,
                                },
                            },
                            .severity = .Error,
                            .message = msg,
                        },
                    };
                },
            }
        },
        .ziggy => {
            var doc = try Document.init(self.gpa, new_text);
            errdefer doc.deinit();

            log.debug("document init", .{});

            const gop = try self.files.getOrPut(self.gpa, uri);
            errdefer _ = self.files.remove(uri);

            if (gop.found_existing) {
                gop.value_ptr.deinit();
            } else {
                gop.key_ptr.* = try self.gpa.dupe(u8, uri);
            }

            gop.value_ptr.* = .{ .ziggy = doc };

            log.debug("sending {} diagnostic errors", .{doc.diagnostic.errors.items.len});

            const diags = try arena.alloc(lsp.types.Diagnostic, doc.diagnostic.errors.items.len);
            for (doc.diagnostic.errors.items, 0..) |e, idx| {
                const msg = try std.fmt.allocPrint(arena, "{lsp}", .{e.fmt(null)});
                const sel = e.getErrorSelection();
                diags[idx] = .{
                    .range = .{
                        .start = .{
                            .line = sel.start.line - 1,
                            .character = sel.start.col - 1,
                        },
                        .end = .{
                            .line = sel.end.line - 1,
                            .character = sel.end.col - 1,
                        },
                    },
                    .severity = .Error,
                    .message = msg,
                };
            }

            res.diagnostics = diags;
        },
    }
    log.debug("sending diags!", .{});
    const msg = try self.server.sendToClientNotification(
        "textDocument/publishDiagnostics",
        res,
    );

    defer self.gpa.free(msg);
}
