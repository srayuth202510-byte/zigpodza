//! Shell tab-completion script generator for bash, zsh, and fish.
const std = @import("std");
const cli_types = @import("cli_types.zig");

pub const Shell = cli_types.Shell;

const subcommands = "run ps images pull rmi tag history commit start stop restart pause unpause rename kill rm logs top exec inspect stats volume network system port wait diff events policy completion audit demo version help";

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
    \\        volume)
    \\            COMPREPLY=( $(compgen -W "ls create rm inspect" -- "${{cur}}") )
    \\            ;;
    \\        network)
    \\            COMPREPLY=( $(compgen -W "ls inspect" -- "${{cur}}") )
    \\            ;;
    \\        system)
    \\            COMPREPLY=( $(compgen -W "ping df prune" -- "${{cur}}") )
    \\            ;;
    \\        run)
    \\            COMPREPLY=( $(compgen -W "-d --detach --rm --name -e --env -v --volume -p --publish --network -w --workdir -u --user --cap-drop --cap-add -m --memory --pids-limit --read-only --no-new-privileges --profile --policy -i --interactive -t --tty" -- "${{cur}}") )
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
    \\        'inspect:Inspect a container or image'
    \\        'stats:Display container resource usage'
    \\        'volume:Manage named volumes'
    \\        'network:Manage networks'
    \\        'system:System maintenance'
    \\        'port:List container port mappings'
    \\        'wait:Wait for a container to stop'
    \\        'diff:Inspect filesystem changes'
    \\        'events:Stream daemon events'
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
    \\            _values 'action' ls create rm inspect
    \\            ;;
    \\        network)
    \\            _values 'action' ls inspect
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
    \\complete -c zigpod -n "__fish_seen_subcommand_from volume" -a "ls create rm inspect"
    \\complete -c zigpod -n "__fish_seen_subcommand_from network" -a "ls inspect"
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
    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try writeCompletion(.bash, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "complete -F _zigpod_completions zigpod") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "events") != null);

    out.clearRetainingCapacity();
    try writeCompletion(.zsh, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "#compdef zigpod") != null);

    out.clearRetainingCapacity();
    try writeCompletion(.fish, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "complete -c zigpod -f") != null);
}
