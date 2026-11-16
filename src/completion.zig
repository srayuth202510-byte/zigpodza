//! Shell tab-completion script generator for bash, zsh, and fish.
const std = @import("std");
const cli_types = @import("cli_types.zig");

pub const Shell = cli_types.Shell;

const subcommands = "run ps images pull rmi tag history commit build start stop restart pause unpause rename kill rm logs top exec attach inspect stats create container image volume network cp pod compose system port wait diff events policy completion audit demo search save load export import version help";

const bash_template =
    \\# bash completion for zigpod
    \\_zigpod_completions() {{
    \\    local cur
    \\    cur="${{COMP_WORDS[COMP_CWORD]}}"
    \\    if [[ ${{COMP_CWORD}} -eq 1 ]]; then
    \\        COMPREPLY=( $(compgen -W "--socket -v --verbose -h --help --version {s}" -- "${{cur}}") )
    \\        return 0
    \\    fi
    \\    case "${{COMP_WORDS[1]}}" in
    \\        completion)
    \\            COMPREPLY=( $(compgen -W "bash zsh fish" -- "${{cur}}") )
    \\            ;;
    \\        container|image)
    \\            COMPREPLY=( $(compgen -W "prune" -- "${{cur}}") )
    \\            ;;
    \\        volume)
    \\            COMPREPLY=( $(compgen -W "ls create rm inspect prune" -- "${{cur}}") )
    \\            ;;
    \\        network)
    \\            COMPREPLY=( $(compgen -W "ls inspect create rm prune" -- "${{cur}}") )
    \\            ;;
    \\        attach)
    \\            COMPREPLY=( $(compgen -W "-i --interactive -t --tty" -- "${{cur}}") )
    \\            ;;
    \\        pod)
    \\            COMPREPLY=( $(compgen -W "create ps stop rm" -- "${{cur}}") )
    \\            ;;
    \\        compose)
    \\            COMPREPLY=( $(compgen -W "up down ps start stop restart logs exec pull config" -- "${{cur}}") )
    \\            ;;
    \\        policy)
    \\            COMPREPLY=( $(compgen -W "show check" -- "${{cur}}") )
    \\            ;;
    \\        system)
    \\            COMPREPLY=( $(compgen -W "ping df prune" -- "${{cur}}") )
    \\            ;;
    \\        build)
    \\            COMPREPLY=( $(compgen -W "-t --tag -f --file --build-arg --target --no-cache" -- "${{cur}}") )
    \\            ;;
    \\        run)
    \\            COMPREPLY=( $(compgen -W "-d --detach --rm --name -e --env --env-file -v --volume -p --publish -l --label --network -w --workdir -u --user --cap-drop --cap-add -m --memory --cpus --pids-limit --read-only --no-new-privileges --entrypoint --hostname --restart --shm-size --ulimit --init --health-cmd --health-interval --dns --add-host --stop-timeout --platform --pull --profile --policy -i --interactive -t --tty" -- "${{cur}}") )
    \\            ;;
    \\        *)
    \\            COMPREPLY=()
    \\            ;;
    \\    esac
    \\}}
    \\complete -F _zigpod_completions zigpod
    \\
;

const bash_script = std.fmt.comptimePrint(bash_template, .{subcommands});

const zsh_script =
    \\#compdef zigpod
    \\_zigpod() {
    \\    local -a commands
    \\    commands=(
    \\        'run:Create and start a container'
    \\        'ps:List containers'
    \\        'images:List local images'
    \\        'pull:Pull an image'
    \\        'rmi:Remove a local image'
    \\        'tag:Create a tag for a local image'
    \\        'history:Show image history'
    \\        'commit:Create a new image from a container'
    \\        'build:Build an image from a directory'
    \\        'start:Start a container'
    \\        'stop:Stop a container'
    \\        'restart:Restart a container'
    \\        'pause:Pause a container'
    \\        'unpause:Unpause a container'
    \\        'rename:Rename a container'
    \\        'kill:Send a signal to a container'
    \\        'rm:Remove a container'
    \\        'logs:Fetch container logs'
    \\        'top:Display running processes'
    \\        'exec:Execute a command in a container'
    \\        'attach:Attach to a running container'
    \\        'inspect:Inspect a container or image'
    \\        'stats:Display container resource usage'
    \\        'create:Create a container without starting it'
    \\        'container:Manage containers (prune)'
    \\        'image:Manage images (prune)'
    \\        'volume:Manage named volumes'
    \\        'network:Manage networks'
    \\        'cp:Copy files between container and host'
    \\        'pod:Manage pods'
    \\        'compose:Manage multi-container compose stacks'
    \\        'system:System maintenance'
    \\        'port:List container port mappings'
    \\        'wait:Wait for a container to stop'
    \\        'diff:Inspect filesystem changes'
    \\        'events:Stream daemon events'
    \\        'policy:Inspect or validate security policy'
    \\        'search:Search a registry for images'
    \\        'save:Stream an image tarball to a host file'
    \\        'load:Upload a local image tarball to the daemon'
    \\        'export:Stream a container rootfs tarball to a host file'
    \\        'import:Upload a local rootfs tarball as a new image'
    \\        'completion:Generate shell completion'
    \\        'audit:Verify hash-chained audit.log'
    \\        'demo:Run self-test suite'
    \\        'version:Show client and server versions'
    \\        'help:Show help'
    \\    )
    \\    if (( CURRENT == 2 )); then
    \\        _describe 'command' commands
    \\        return
    \\    fi
    \\    case "${words[2]}" in
    \\        completion)
    \\            _values 'shell' bash zsh fish
    \\            ;;
    \\        volume)
    \\            _values 'action' ls create rm inspect prune
    \\            ;;
    \\        network)
    \\            _values 'action' ls inspect create rm prune
    \\            ;;
    \\        pod)
    \\            _values 'action' create ps stop rm
    \\            ;;
    \\        compose)
    \\            _values 'action' up down ps start stop restart logs exec pull config
    \\            ;;
    \\        policy)
    \\            _values 'action' show check
    \\            ;;
    \\        system)
    \\            _values 'action' ping df prune
    \\            ;;
    \\    esac
    \\}
    \\_zigpod "$@"
    \\
;

const fish_template =
    \\# fish completion for zigpod
    \\complete -c zigpod -f
    \\for cmd in {s}
    \\    complete -c zigpod -n "__fish_use_subcommand" -a "$cmd"
    \\end
    \\complete -c zigpod -n "__fish_seen_subcommand_from completion" -a "bash zsh fish"
    \\complete -c zigpod -n "__fish_seen_subcommand_from volume" -a "ls create rm inspect prune"
    \\complete -c zigpod -n "__fish_seen_subcommand_from network" -a "ls inspect create rm prune"
    \\complete -c zigpod -n "__fish_seen_subcommand_from pod" -a "create ps stop rm"
    \\complete -c zigpod -n "__fish_seen_subcommand_from compose" -a "up down ps start stop restart logs exec pull config"
    \\complete -c zigpod -n "__fish_seen_subcommand_from policy" -a "show check"
    \\complete -c zigpod -n "__fish_seen_subcommand_from system" -a "ping df prune"
    \\
;

const fish_script = std.fmt.comptimePrint(fish_template, .{subcommands});

pub fn writeCompletion(shell: Shell, writer: anytype) !void {
    switch (shell) {
        .bash => try writer.writeAll(bash_script),
        .zsh => try writer.writeAll(zsh_script),
        .fish => try writer.writeAll(fish_script),
    }
}

// ---------------------------------------------------------------- tests

test "writeCompletion emits valid scripts for bash, zsh, and fish" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeCompletion(.bash, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "complete -F _zigpod_completions zigpod") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "events") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "build") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "pod") != null);

    out.clearRetainingCapacity();
    try writeCompletion(.zsh, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "#compdef zigpod") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "'build:Build an image from a directory'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "'pod:Manage pods'") != null);

    out.clearRetainingCapacity();
    try writeCompletion(.fish, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "complete -c zigpod -f") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "__fish_seen_subcommand_from pod") != null);
}

test "bash script wires top-level commands, flags, and subcommand branches" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeCompletion(.bash, &out.writer);
    const s = out.written();

    try std.testing.expect(std.mem.indexOf(u8, s, "# bash completion for zigpod") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "-W \"--socket -v --verbose -h --help --version run ps images") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "completion)\n            COMPREPLY=( $(compgen -W \"bash zsh fish\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "volume)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "network)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "attach)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "policy)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "system)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "--pids-limit --read-only --no-new-privileges") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "--cpus") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "--env-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "--restart") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "complete -F _zigpod_completions zigpod") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "{s}") == null);
}

test "zsh script registers all subcommands and per-command actions" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeCompletion(.zsh, &out.writer);
    const s = out.written();

    try std.testing.expect(std.mem.indexOf(u8, s, "#compdef zigpod") != null);
    for ([_][]const u8{ "run", "ps", "images", "pull", "rmi", "tag", "history", "commit", "build", "start", "stop", "restart", "pause", "unpause", "rename", "kill", "rm", "logs", "create", "container", "image", "top", "exec", "attach", "inspect", "stats", "volume", "network", "cp", "pod", "system", "port", "wait", "diff", "events", "policy", "completion", "audit", "demo", "version", "help" }) |cmd| {
        var line_buf: std.Io.Writer.Allocating = .init(alloc);
        defer line_buf.deinit();
        try line_buf.writer.print("'{s}:", .{cmd});
        try std.testing.expect(std.mem.indexOf(u8, s, line_buf.written()) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, s, "(( CURRENT == 2 ))") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "_values 'shell' bash zsh fish") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "_values 'action' ping df prune") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "_zigpod \"$@\"") != null);
}

test "fish script lists every subcommand under __fish_use_subcommand" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeCompletion(.fish, &out.writer);
    const s = out.written();

    try std.testing.expect(std.mem.indexOf(u8, s, "# fish completion for zigpod") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__fish_use_subcommand") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__fish_seen_subcommand_from volume") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__fish_seen_subcommand_from network") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__fish_seen_subcommand_from system") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "{s}") == null);
}

test "each shell emits a distinct non-empty script" {
    const alloc = std.testing.allocator;
    var b: std.Io.Writer.Allocating = .init(alloc);
    defer b.deinit();
    var z: std.Io.Writer.Allocating = .init(alloc);
    defer z.deinit();
    var f: std.Io.Writer.Allocating = .init(alloc);
    defer f.deinit();

    try writeCompletion(.bash, &b.writer);
    try writeCompletion(.zsh, &z.writer);
    try writeCompletion(.fish, &f.writer);

    try std.testing.expect(b.written().len > 0);
    try std.testing.expect(z.written().len > 0);
    try std.testing.expect(f.written().len > 0);
    try std.testing.expect(!std.mem.eql(u8, b.written(), z.written()));
    try std.testing.expect(!std.mem.eql(u8, z.written(), f.written()));
    try std.testing.expect(!std.mem.eql(u8, b.written(), f.written()));
}
