const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.runfiles);

const max_path_bytes = std.fs.max_path_bytes;

const discovery = @import("discovery.zig");
const Directory = @import("Directory.zig");
const Manifest = @import("Manifest.zig");
const RepoMapping = @import("RepoMapping.zig");
const RPath = @import("RPath.zig");

const EnvMap = std.process.Environ.Map;

const Runfiles = @This();

implementation: Implementation,
repo_mapping: ?RepoMapping,

pub const CreateOptions = discovery.DiscoverOptions;

pub const CreateError = discovery.DiscoverError || Manifest.InitError || Directory.InitError || RepoMapping.InitError;

/// Performs runfiles discovery to determine the runfiles strategy and
/// location, and creates the runfiles object. Returns `null` if no runfiles
/// where found.
///
/// You must invoke `deinit` passing the same allocator to free resources.
///
/// Quoting the [runfiles design][runfiles-design] for further details:
///
/// > Every language's library will have a similar interface: a Create method
/// > that inspects the environment and/or `argv[0]` to determine the runfiles
/// > strategy (manifest-based or directory-based; see below), initializes
/// > runfiles handling and returns a Runfiles object.
///
/// > Runfiles strategies:
/// >
/// > * Manifest-based: reads the runfiles manifest file to look up runfiles.
/// > * Directory-based: appends the runfile's path to the runfiles root. The
/// >   client is responsible for checking that the resulting path exists.
///
/// > The unified runfiles discovery strategy is to:
/// > * check if `RUNFILES_MANIFEST_FILE` or `RUNFILES_DIR` envvars are set,
///     and again initialize a Runfiles object accordingly; otherwise
/// > * check if the `argv[0] + ".runfiles_manifest"` file or the
/// >   `argv[0] + ".runfiles"` directory exists (keeping in mind that argv[0]
/// >   may not include the `".exe"` suffix on Windows), and if so, initialize
/// >   a manifest- or directory-based Runfiles object; otherwise
/// > * assume the binary has no runfiles.
///
/// [runfiles-design]: https://docs.google.com/document/d/e/2PACX-1vSDIrFnFvEYhKsCMdGdD40wZRBX3m3aZ5HhVj4CtHPmiXKDCxioTUbYsDydjKtFDAzER5eg7OjJWs3V/pub
pub fn create(options: CreateOptions) CreateError!?Runfiles {
    var implementation = discover: {
        const result = try discovery.discoverRunfiles(options) orelse
            return null;
        switch (result) {
            .manifest => |path| {
                defer options.allocator.free(path);
                const manifest = try Manifest.init(options.allocator, options.io, path);
                break :discover Implementation{ .manifest = manifest };
            },
            .directory => |path| {
                defer options.allocator.free(path);
                const directory = try Directory.init(options.allocator, options.io, path);
                break :discover Implementation{ .directory = directory };
            },
        }
    };
    errdefer implementation.deinit(options.allocator);

    const repo_mapping = try implementation.loadRepoMapping(options.allocator, options.io);

    return Runfiles{
        .implementation = implementation,
        .repo_mapping = repo_mapping,
    };
}

/// You must pass the same allocator as to `create`.
pub fn deinit(self: *Runfiles, allocator: std.mem.Allocator) void {
    self.implementation.deinit(allocator);
    if (self.repo_mapping) |*repo_mapping| repo_mapping.deinit(allocator);
}

pub const WithSourceRepo = struct {
    runfiles: *const Runfiles,
    source_repo: []const u8,

    pub const RLocationError = error{
        NoSpaceLeft,
        WriteFailed,
        NameTooLong,
    } || ValidationError;

    /// Resolves the given runfiles location path `rpath`,
    /// and returns an absolute path to the item.
    /// Note, the returned path may point to a non-existing file.
    /// Returns `null` under the manifest based strategy
    /// if the runfiles path was not found.
    ///
    /// Prefer to use Bazel's `$(rlocationpath ...)` expansion in your
    /// `BUILD.bazel` file to obtain a runfiles path.
    ///
    /// Quoting the [runfiles design][runfiles-design] for further details:
    ///
    /// > Every language's library will have a similar interface: an
    /// > Rlocation(string) method that expects a runfiles-root-relative path
    /// > (case-sensitive on Linux/macOS, case-insensitive on Windows) and returns
    /// > the absolute path of the file, which is normalized (and lowercase on
    /// > Windows) and uses "/" as directory separator on every platform (including
    /// > Windows)
    ///
    /// TODO: Path normalization, in particular lower-case and '/' normalization on
    ///   Windows, is not yet implemented.
    ///
    /// [runfiles-design]: https://docs.google.com/document/d/e/2PACX-1vSDIrFnFvEYhKsCMdGdD40wZRBX3m3aZ5HhVj4CtHPmiXKDCxioTUbYsDydjKtFDAzER5eg7OjJWs3V/pub
    pub fn rlocation(
        self: WithSourceRepo,
        rpath: []const u8,
        out_buffer: []u8,
    ) RLocationError!?[]const u8 {
        try validateRPath(rpath);
        const rpath_ = self.runfiles.remapRPath(rpath, self.source_repo);
        return try self.runfiles.implementation.rlocationUnmapped(rpath_, out_buffer);
    }

    /// Allocating variant of `rlocation`.
    /// The caller owns the returned path.
    pub fn rlocationAlloc(
        self: WithSourceRepo,
        allocator: std.mem.Allocator,
        rpath: []const u8,
    ) (error{OutOfMemory} || RLocationError)!?[]const u8 {
        try validateRPath(rpath);
        const rpath_ = self.runfiles.remapRPath(rpath, self.source_repo);
        return try self.runfiles.implementation.rlocationUnmappedAlloc(allocator, rpath_);
    }

    pub const ValidationError = error{
        RPathIsAbsolute,
        RPathContainsSelfReference,
        RPathContainsUpReference,
    };

    fn validateRPath(rpath: []const u8) !void {
        var iter = std.fs.path.componentIterator(rpath);

        if (iter.root() != null)
            return error.RPathIsAbsolute;

        while (iter.next()) |component| {
            if (std.mem.eql(u8, ".", component.name))
                return error.RPathContainsSelfReference;

            if (std.mem.eql(u8, "..", component.name))
                return error.RPathContainsUpReference;
        }
    }
};

/// Runfiles path lookup is subject to repository mapping and will be resolved
/// relative to the given source repository name `source_repo`.
/// Use the automatically generated `bazel_builtin` module to obtain the
/// current repository name.
///
/// The returned `WithSourceRepo` holds a reference to `self` and
/// `source_repo`.
pub fn withSourceRepo(self: *const Runfiles, source_repo: []const u8) WithSourceRepo {
    return .{
        .runfiles = self,
        .source_repo = source_repo,
    };
}

/// Set the required environment variables to discover the same runfiles. Use
/// this if you invoke another process that needs to resolve runfiles location
/// paths.
pub fn environment(self: *const Runfiles, output_env: *EnvMap) error{OutOfMemory}!void {
    try self.implementation.environment(output_env);
}

fn remapRPath(self: *const Runfiles, rpath: []const u8, source: []const u8) RPath {
    var rpath_ = RPath.init(rpath);
    if (self.repo_mapping) |repo_mapping| {
        const key = RepoMapping.Key{ .source = source, .target = rpath_.repo };
        if (repo_mapping.lookup(key)) |mapped|
            rpath_.repo = mapped;
        // NOTE, the spec states that we should fail if no mapping is found
        // and the repo name is not canonical. However, this always fails
        // in WORKSPACE mode and is apparently an issue in the spec and
        // common runfiles library implementations do not follow this
        // pattern.
    }
    return rpath_;
}

const Implementation = union(discovery.Strategy) {
    manifest: Manifest,
    directory: Directory,

    pub fn deinit(self: *Implementation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .manifest => |*manifest| manifest.deinit(allocator),
            .directory => |*directory| directory.deinit(allocator),
        }
    }

    pub fn rlocationUnmapped(
        self: *const Implementation,
        rpath: RPath,
        out_buffer: []u8,
    ) !?[]const u8 {
        switch (self.*) {
            .manifest => |*manifest| {
                const path = manifest.rlocationUnmapped(rpath) orelse
                    return null;
                if (path.len > out_buffer.len)
                    return error.NameTooLong;
                const result = out_buffer[0..path.len];
                @memcpy(result, path);
                return result;
            },
            .directory => |*directory| {
                return try directory.rlocationUnmapped(rpath, out_buffer);
            },
        }
    }

    pub fn rlocationUnmappedAlloc(
        self: *const Implementation,
        allocator: std.mem.Allocator,
        rpath: RPath,
    ) !?[]const u8 {
        switch (self.*) {
            .manifest => |*manifest| {
                const path = manifest.rlocationUnmapped(rpath) orelse
                    return null;
                return try allocator.dupe(u8, path);
            },
            .directory => |*directory| {
                return try directory.rlocationUnmappedAlloc(allocator, rpath);
            },
        }
    }

    pub fn environment(self: *const Implementation, output_env: *EnvMap) !void {
        switch (self.*) {
            .manifest => |*manifest| try output_env.put(discovery.runfiles_manifest_var_name, manifest.path),
            .directory => |*directory| try output_env.put(discovery.runfiles_directory_var_name, directory.path),
        }
    }

    pub fn loadRepoMapping(self: *const Implementation, allocator: std.mem.Allocator, io: std.Io) !?RepoMapping {
        // Bazel <7 with bzlmod disabled does not generate a repo-mapping.
        const msg_not_found = "No repository mapping found. " ++
            "This is likely an error if you are using Bazel version >=7 with bzlmod enabled.";

        const path = try self.rlocationUnmappedAlloc(allocator, .{
            .repo = "",
            .path = discovery.repo_mapping_file_name,
        }) orelse {
            log.warn(msg_not_found, .{});
            return null;
        };
        defer allocator.free(path);

        return RepoMapping.init(allocator, io, path) catch |e| switch (e) {
            error.FileNotFound => {
                log.warn(msg_not_found, .{});
                return null;
            },
            else => |e_| return e_,
        };
    }
};

test "Runfiles from manifest" {
    const testutil = @import("testutil.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpMakePath(tmp.dir, "some/package");
    try testutil.tmpMakePath(tmp.dir, "other/package");
    try testutil.tmpWriteFile(tmp.dir, "test.repo_mapping",
        \\,my_module,my_workspace
        \\,other_module,other~3.4.5
        \\their_module~1.2.3,another_module,other~3.4.5
    );
    try testutil.tmpWriteFile(tmp.dir, "some/package/some_file", "some_content");
    try testutil.tmpWriteFile(tmp.dir, "other/package/other_file", "other_content");
    {
        const repo_mapping_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.repo_mapping");
        defer std.testing.allocator.free(repo_mapping_path);
        const some_file_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "some/package/some_file");
        defer std.testing.allocator.free(some_file_path);
        const other_file_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "other/package/other_file");
        defer std.testing.allocator.free(other_file_path);
        const manifest_content = try std.fmt.allocPrint(
            std.testing.allocator,
            "_repo_mapping {s}\nmy_workspace/some/package/some_file {s}\nother~3.4.5/other/package/other_file {s}\n",
            .{
                repo_mapping_path,
                some_file_path,
                other_file_path,
            },
        );
        defer std.testing.allocator.free(manifest_content);
        try testutil.tmpWriteFile(tmp.dir, "test.runfiles_manifest", manifest_content);
    }
    const manifest_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles_manifest");
    defer std.testing.allocator.free(manifest_path);

    var runfiles = try Runfiles.create(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .manifest = manifest_path,
    }) orelse
        return error.RunfilesNotFound;
    defer runfiles.deinit(std.testing.allocator);

    {
        var buffer: [max_path_bytes]u8 = undefined;
        const file_path = try runfiles
            .withSourceRepo("")
            .rlocation(
            "my_module/some/package/some_file",
            &buffer,
        ) orelse
            return error.TestRLocationNotFound;
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("some_content", content);
    }

    {
        const file_path = try runfiles
            .withSourceRepo("")
            .rlocationAlloc(
            std.testing.allocator,
            "other_module/other/package/other_file",
        ) orelse
            return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("other_content", content);
    }

    {
        const file_path = try runfiles
            .withSourceRepo("their_module~1.2.3")
            .rlocationAlloc(
            std.testing.allocator,
            "another_module/other/package/other_file",
        ) orelse
            return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("other_content", content);
    }

    {
        var env = EnvMap.init(std.testing.allocator);
        defer env.deinit();
        try runfiles.environment(&env);
        try std.testing.expectEqual(@as(usize, 1), env.count());
        try std.testing.expectEqualStrings(manifest_path, env.get(discovery.runfiles_manifest_var_name).?);
    }
}

test "Runfiles from manifest with compact repo mapping" {
    const testutil = @import("testutil.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo_mapping_contents =
        \\,config.json,config.json+1.2.3
        \\,my_module,_main
        \\,my_protobuf,protobuf+3.19.2
        \\,my_workspace,_main
        \\my_module++ext+*,my_module,my_module+
        \\my_module++ext+*,repo1,my_module++ext+repo1
    ;

    try testutil.tmpMakePath(tmp.dir, "my_module+");
    try testutil.tmpMakePath(tmp.dir, "my_module++ext+repo1");
    try testutil.tmpMakePath(tmp.dir, "repo2+");
    try testutil.tmpWriteFile(tmp.dir, "foo.repo_mapping", repo_mapping_contents);
    try testutil.tmpWriteFile(tmp.dir, "config.json", "config");
    try testutil.tmpWriteFile(tmp.dir, "my_module+/foo", "my_module+");
    try testutil.tmpWriteFile(tmp.dir, "my_module++ext+repo1/foo", "ext_repo1");
    try testutil.tmpWriteFile(tmp.dir, "repo2+/foo", "repo2+");

    {
        const repo_mapping_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "foo.repo_mapping");
        defer std.testing.allocator.free(repo_mapping_path);
        const config_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "config.json");
        defer std.testing.allocator.free(config_path);
        const my_module_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "my_module+/foo");
        defer std.testing.allocator.free(my_module_path);
        const ext_repo1_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "my_module++ext+repo1/foo");
        defer std.testing.allocator.free(ext_repo1_path);
        const repo2_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "repo2+/foo");
        defer std.testing.allocator.free(repo2_path);
        const manifest_content = try std.fmt.allocPrint(
            std.testing.allocator,
            "_repo_mapping {s}\nconfig.json {s}\nmy_module+/foo {s}\nmy_module++ext+repo1/foo {s}\nrepo2+/foo {s}\n",
            .{
                repo_mapping_path,
                config_path,
                my_module_path,
                ext_repo1_path,
                repo2_path,
            },
        );
        defer std.testing.allocator.free(manifest_content);
        try testutil.tmpWriteFile(tmp.dir, "foo.runfiles_manifest", manifest_content);
    }

    const manifest_path = try testutil.tmpRealpathAlloc(
        tmp.dir,
        std.testing.allocator,
        "foo.runfiles_manifest",
    );
    defer std.testing.allocator.free(manifest_path);

    var runfiles = try Runfiles.create(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .manifest = manifest_path,
    }) orelse return error.RunfilesNotFound;
    defer runfiles.deinit(std.testing.allocator);

    {
        const file_path = try runfiles
            .withSourceRepo("my_module++ext+repo1")
            .rlocationAlloc(
            std.testing.allocator,
            "my_module/foo",
        ) orelse return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("my_module+", content);
    }

    {
        const file_path = try runfiles
            .withSourceRepo("my_module++ext+repo1")
            .rlocationAlloc(
            std.testing.allocator,
            "repo1/foo",
        ) orelse return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("ext_repo1", content);
    }

    {
        const file_path = try runfiles
            .withSourceRepo("my_module++ext+repo1")
            .rlocationAlloc(
            std.testing.allocator,
            "repo2+/foo",
        ) orelse return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("repo2+", content);
    }
}

test "Runfiles from directory" {
    const testutil = @import("testutil.zig");
    if (builtin.os.tag == .windows)
        // Windows does not support symlinks out of the box.
        return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpMakePath(tmp.dir, "some/package");
    try testutil.tmpMakePath(tmp.dir, "other/package");
    try testutil.tmpWriteFile(tmp.dir, "test.repo_mapping",
        \\,my_module,my_workspace
        \\,other_module,other~3.4.5
        \\their_module~1.2.3,another_module,other~3.4.5
    );
    try testutil.tmpWriteFile(tmp.dir, "some/package/some_file", "some_content");
    try testutil.tmpWriteFile(tmp.dir, "other/package/other_file", "other_content");
    {
        var buf: [max_path_bytes]u8 = undefined;
        try testutil.tmpMakeDir(tmp.dir, "test.runfiles");
        try testutil.tmpSymLink(
            tmp.dir,
            try testutil.tmpRealpath(tmp.dir, "test.repo_mapping", &buf),
            "test.runfiles/_repo_mapping",
        );
        try testutil.tmpMakePath(tmp.dir, "test.runfiles/my_workspace/some/package");
        try testutil.tmpSymLink(
            tmp.dir,
            try testutil.tmpRealpath(tmp.dir, "some/package/some_file", &buf),
            "test.runfiles/my_workspace/some/package/some_file",
        );
        try testutil.tmpMakePath(tmp.dir, "test.runfiles/other~3.4.5/other/package");
        try testutil.tmpSymLink(
            tmp.dir,
            try testutil.tmpRealpath(tmp.dir, "other/package/other_file", &buf),
            "test.runfiles/other~3.4.5/other/package/other_file",
        );
    }
    const directory_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles");
    defer std.testing.allocator.free(directory_path);

    var runfiles = try Runfiles.create(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .directory = directory_path,
    }) orelse
        return error.RunfilesNotFound;
    defer runfiles.deinit(std.testing.allocator);

    {
        var buffer: [max_path_bytes]u8 = undefined;
        const file_path = try runfiles
            .withSourceRepo("")
            .rlocation(
            "my_module/some/package/some_file",
            &buffer,
        ) orelse
            return error.TestRLocationNotFound;
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("some_content", content);
    }

    {
        const file_path = try runfiles
            .withSourceRepo("")
            .rlocationAlloc(
            std.testing.allocator,
            "other_module/other/package/other_file",
        ) orelse
            return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("other_content", content);
    }

    {
        const file_path = try runfiles
            .withSourceRepo("their_module~1.2.3")
            .rlocationAlloc(
            std.testing.allocator,
            "another_module/other/package/other_file",
        ) orelse
            return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("other_content", content);
    }

    {
        var env = EnvMap.init(std.testing.allocator);
        defer env.deinit();
        try runfiles.environment(&env);
        try std.testing.expectEqual(@as(usize, 1), env.count());
        try std.testing.expectEqualStrings(directory_path, env.get(discovery.runfiles_directory_var_name).?);
    }
}

test "Runfiles from directory with compact repo mapping" {
    const testutil = @import("testutil.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo_mapping_contents =
        \\,config.json,config.json+1.2.3
        \\,my_module,_main
        \\,my_protobuf,protobuf+3.19.2
        \\,my_workspace,_main
        \\my_module++ext+*,my_module,my_module+
        \\my_module++ext+*,repo1,my_module++ext+repo1
    ;

    try testutil.tmpMakePath(tmp.dir, "my_module+");
    try testutil.tmpMakePath(tmp.dir, "my_module++ext+repo1");
    try testutil.tmpMakePath(tmp.dir, "repo2+");
    try testutil.tmpWriteFile(tmp.dir, "foo.repo_mapping", repo_mapping_contents);
    try testutil.tmpWriteFile(tmp.dir, "config.json", "config");
    try testutil.tmpWriteFile(tmp.dir, "my_module+/foo", "my_module+");
    try testutil.tmpWriteFile(tmp.dir, "my_module++ext+repo1/foo", "ext_repo1");
    try testutil.tmpWriteFile(tmp.dir, "repo2+/foo", "repo2+");

    {
        var buf: [max_path_bytes]u8 = undefined;
        try testutil.tmpMakeDir(tmp.dir, "foo.runfiles");
        try testutil.tmpSymLink(
            tmp.dir,
            try testutil.tmpRealpath(tmp.dir, "foo.repo_mapping", &buf),
            "foo.runfiles/_repo_mapping",
        );
        try testutil.tmpSymLink(
            tmp.dir,
            try testutil.tmpRealpath(tmp.dir, "config.json", &buf),
            "foo.runfiles/config.json",
        );
        try testutil.tmpMakePath(tmp.dir, "foo.runfiles/my_module+");
        try testutil.tmpSymLink(
            tmp.dir,
            try testutil.tmpRealpath(tmp.dir, "my_module+/foo", &buf),
            "foo.runfiles/my_module+/foo",
        );
        try testutil.tmpMakePath(tmp.dir, "foo.runfiles/my_module++ext+repo1");
        try testutil.tmpSymLink(
            tmp.dir,
            try testutil.tmpRealpath(tmp.dir, "my_module++ext+repo1/foo", &buf),
            "foo.runfiles/my_module++ext+repo1/foo",
        );
        try testutil.tmpMakePath(tmp.dir, "foo.runfiles/repo2+");
        try testutil.tmpSymLink(
            tmp.dir,
            try testutil.tmpRealpath(tmp.dir, "repo2+/foo", &buf),
            "foo.runfiles/repo2+/foo",
        );
    }
    const directory_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "foo.runfiles");
    defer std.testing.allocator.free(directory_path);

    var runfiles = try Runfiles.create(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .directory = directory_path,
    }) orelse
        return error.RunfilesNotFound;
    defer runfiles.deinit(std.testing.allocator);

    {
        const file_path = try runfiles
            .withSourceRepo("my_module++ext+repo1")
            .rlocationAlloc(
            std.testing.allocator,
            "my_module/foo",
        ) orelse return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("my_module+", content);
    }

    {
        const file_path = try runfiles
            .withSourceRepo("my_module++ext+repo1")
            .rlocationAlloc(
            std.testing.allocator,
            "repo1/foo",
        ) orelse return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("ext_repo1", content);
    }

    {
        const file_path = try runfiles
            .withSourceRepo("my_module++ext+repo1")
            .rlocationAlloc(
            std.testing.allocator,
            "repo2+/foo",
        ) orelse return error.TestRLocationNotFound;
        defer std.testing.allocator.free(file_path);
        try std.testing.expect(std.fs.path.isAbsolute(file_path));
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, file_path, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("repo2+", content);
    }
}

test "rpath validation" {
    const r_ = Runfiles{
        .implementation = Implementation{ .directory = .{ .path = "/does-not-exist" } },
        .repo_mapping = null,
    };
    const r = r_.withSourceRepo("");
    var buf: [32]u8 = undefined;
    try std.testing.expectError(error.RPathIsAbsolute, r.rlocationAlloc(std.testing.allocator, "/absolute/path"));
    try std.testing.expectError(error.RPathContainsSelfReference, r.rlocation("self/reference/./path", &buf));
    try std.testing.expectError(error.RPathContainsUpReference, r.rlocationAlloc(std.testing.allocator, "up/reference/../path"));
}
