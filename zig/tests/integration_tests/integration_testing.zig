const std = @import("std");

/// Location of the Bazel workspace directory under test.
const BIT_WORKSPACE_DIR = "BIT_WORKSPACE_DIR";

/// Location of the Bazel binary.
const BIT_BAZEL_BINARY = "BIT_BAZEL_BINARY";

const Term = std.process.Child.Term;
pub const EnvMap = std.process.Environ.Map;

fn termSucceeded(term: Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn currentEnvMap(allocator: std.mem.Allocator) !EnvMap {
    return try std.process.Environ.createMap(std.testing.environ, allocator);
}

pub fn removeEnv(env_map: *EnvMap, key: []const u8) void {
    _ = env_map.swapRemove(key);
}

fn getEnvOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var env_map = try currentEnvMap(allocator);
    defer env_map.deinit();
    const value = env_map.get(key) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
}

/// Bazel integration testing context.
///
/// Provides access to the Bazel binary and the workspace directory under test.
pub const BitContext = struct {
    workspace_path: []const u8,
    bazel_path: []const u8,

    pub fn init() !BitContext {
        const workspace_path = getEnvOwned(std.testing.allocator, BIT_WORKSPACE_DIR) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                std.log.err("Required environment variable not found: {s}", .{BIT_WORKSPACE_DIR});
                return error.EnvironmentVariableNotFound;
            },
            else => |e| return e,
        };
        errdefer std.testing.allocator.free(workspace_path);

        const bazel_path = getEnvOwned(std.testing.allocator, BIT_BAZEL_BINARY) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                std.log.err("Required environment variable not found: {s}", .{BIT_BAZEL_BINARY});
                return error.EnvironmentVariableNotFound;
            },
            else => |e| return e,
        };
        return BitContext{
            .workspace_path = workspace_path,
            .bazel_path = bazel_path,
        };
    }

    pub fn deinit(self: BitContext) void {
        std.testing.allocator.free(self.workspace_path);
        std.testing.allocator.free(self.bazel_path);
    }

    pub fn openWorkspace(self: BitContext) !std.Io.Dir {
        return try std.Io.Dir.openDirAbsolute(std.testing.io, self.workspace_path, .{});
    }

    pub fn closeWorkspaceDir(dir: *std.Io.Dir) void {
        dir.close(std.testing.io);
    }

    pub fn openWorkspaceFile(self: BitContext, sub_path: []const u8) !std.Io.File {
        var workspace = try self.openWorkspace();
        defer closeWorkspaceDir(&workspace);
        return try workspace.openFile(std.testing.io, sub_path, .{});
    }

    pub fn closeWorkspaceFile(file: *std.Io.File) void {
        file.close(std.testing.io);
    }

    pub fn readWorkspaceFileAlloc(self: BitContext, sub_path: []const u8, max_bytes: usize) ![]u8 {
        var workspace = try self.openWorkspace();
        defer closeWorkspaceDir(&workspace);
        return try workspace.readFileAlloc(std.testing.io, sub_path, std.testing.allocator, .limited(max_bytes));
    }

    pub fn workspaceFileExists(self: BitContext, sub_path: []const u8) !bool {
        var file = self.openWorkspaceFile(sub_path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        closeWorkspaceFile(&file);
        return true;
    }

    pub fn workspaceDirExists(self: BitContext, sub_path: []const u8) !bool {
        var workspace = try self.openWorkspace();
        defer closeWorkspaceDir(&workspace);

        var dir = workspace.openDir(std.testing.io, sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        closeWorkspaceDir(&dir);
        return true;
    }

    pub fn writeWorkspaceFile(self: BitContext, sub_path: []const u8, content: []const u8) !void {
        var workspace = try self.openWorkspace();
        defer closeWorkspaceDir(&workspace);
        workspace.deleteFile(std.testing.io, sub_path) catch {};
        var file = try workspace.createFile(std.testing.io, sub_path, .{});
        defer file.close(std.testing.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(std.testing.io, &buffer);
        try writer.interface.writeAll(content);
        try writer.interface.flush();
    }

    /// Replace each `needle` with its `replacement` in a workspace file, writing
    /// a fresh file so the original source (a symlink in the test sandbox) is
    /// never modified.
    pub fn patchWorkspaceFile(
        self: BitContext,
        sub_path: []const u8,
        replacements: []const [2][]const u8,
    ) !void {
        var content = try self.readWorkspaceFileAlloc(sub_path, 4 * 1024 * 1024);
        for (replacements) |replacement| {
            const patched = try std.mem.replaceOwned(u8, std.testing.allocator, content, replacement[0], replacement[1]);
            std.testing.allocator.free(content);
            content = patched;
        }
        defer std.testing.allocator.free(content);
        try self.writeWorkspaceFile(sub_path, content);
    }

    pub const BazelResult = struct {
        success: bool,
        term: Term,
        stdout: []u8,
        stderr: []u8,

        pub fn deinit(self: BazelResult) void {
            std.testing.allocator.free(self.stdout);
            std.testing.allocator.free(self.stderr);
        }
    };

    pub fn exec_bazel(
        self: BitContext,
        args: struct {
            argv: []const []const u8,
            print_on_error: bool = true,
            extra_env: ?*const EnvMap = null,
        },
    ) !BazelResult {
        const argc = 1 + args.argv.len;
        var argv = try std.testing.allocator.alloc([]const u8, argc);
        defer std.testing.allocator.free(argv);
        argv[0] = self.bazel_path;
        for (args.argv, 0..) |arg, i| {
            argv[i + 1] = arg;
        }
        var env_map: ?EnvMap = null;
        defer if (env_map) |*env| env.deinit();
        if (args.extra_env) |extra_env| {
            env_map = try currentEnvMap(std.testing.allocator);
            var iter = extra_env.iterator();
            while (iter.next()) |item|
                try env_map.?.put(item.key_ptr.*, item.value_ptr.*);
        }
        const result = try runBazel(self, argv, if (env_map) |*env| env else null);
        if (args.print_on_error and !result.success) {
            std.debug.print("\n{s}\n{s}\n", .{ result.stdout, result.stderr });
        }
        return result;
    }

    fn runBazel(self: BitContext, argv: []const []const u8, env_map: ?*EnvMap) !BazelResult {
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = argv,
            .cwd = .{ .path = self.workspace_path },
            .environ_map = env_map,
        });
        return .{
            .success = termSucceeded(result.term),
            .term = result.term,
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }
};
