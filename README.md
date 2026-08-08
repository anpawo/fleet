# Fleet

A macOS background app that shows you every Claude Code session on your machine the moment you
stop working — so you come back from a coffee and immediately see which sessions finished, which
are still grinding, and which are sitting there waiting for you to answer something.

![The panel](docs/panel.png)

Go idle for a couple of minutes and a panel appears. One tile per running session, each bordered
by what it's doing:

| Border | Meaning |
|--------|---------|
| 🟩 **green** | finished its turn, ready for a new prompt |
| 🟥 **red** | a tool is running right now |
| 🟦 **blue** | blocked on you — a question or a permission approval |

A tile is deliberately close to empty: the project name, the border colour, the state, and —
only while it's working — the one step in flight. The directory is shown only when it isn't
just the project name again. This is a thing you read in half a second from across the desk,
not a dashboard; `--scan` is there when you want the details.

Click a tile and the panel disappears, and the terminal tab running that session comes to the
front with your cursor ready to type. Press <kbd>Esc</kbd>, or click the background, to just
dismiss it.

Sessions that need you are sorted first.

## Opening it yourself

Waiting to go idle is the point, but not when you just want to check on things. Either of these
brings the panel up immediately, and repeating it puts the panel away again:

- **Spotlight** — <kbd>⌘</kbd><kbd>Space</kbd>, type `Fleet`, <kbd>↵</kbd>
- **the `fleet` command** — installed to `~/.local/bin/fleet`

Both reach the copy that's already running rather than starting a second one, so there's never
more than one agent scanning.

## Install

```bash
git clone https://github.com/anpawo/fleet.git
cd fleet
./install.sh
```

That builds the app, installs it to `~/Applications`, registers a LaunchAgent so it starts at
every login and restarts if it ever dies, and drops a `fleet` command in `~/.local/bin`. Nothing
else to configure.

The first time you click a tile, macOS asks whether Fleet may control Terminal. Approve
it — without that permission a click can only raise the terminal app, not the specific tab.

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

To remove it entirely: `./uninstall.sh`

## Battery

This runs all day, so it's built to cost as close to nothing as possible.

**It does no work when you have no sessions open.** Every 60 seconds it asks the kernel for the
process list and checks whether anything named `claude` is alive. If not, it stops there — no
file reads, no UI, no allocations. That check is a couple of syscalls.

When sessions *are* alive it additionally reads the idle timer every 15 seconds, which is a
single in-process call, not a poll of anything. Transcripts are only parsed once you've actually
gone idle and the panel is about to appear.

The specific things it refuses to do:

- **Never shells out.** No `ps`, no `lsof`, no `pgrep`. Everything comes from `libproc` and
  `sysctl` directly. Forking a process on a timer is the most expensive thing a background agent
  can do, and it's completely avoidable.
- **Never screenshots.** Capturing terminal windows would need ScreenCaptureKit, the Screen
  Recording permission, and real GPU work every refresh. Everything on a tile comes from the
  session's own JSONL transcript instead, which is cheaper to read, sharper at tile size, and
  needs no permission at all.
- **Only re-parses what changed.** Transcripts are `stat`ed and skipped unless their size or
  mtime moved, and only the last 256 KB of a file is ever read.
- **Timers carry 50% tolerance**, so macOS coalesces the wakeups with other timers instead of
  waking the CPU on our behalf.
- **Stops dead on sleep.** All timers are torn down on sleep or display-off and rebuilt on wake.
- **No live blur.** The panel backdrop is a flat scrim — a full-screen material would be
  continuous GPU work on a window whose entire purpose is to save power.
- Runs as a `Background` / `LowPriorityIO` LaunchAgent, so the scheduler treats it accordingly.

While the panel is actually on screen it refreshes every 3 seconds. That's the only period where
it does meaningful work, and it ends as soon as you click.

## How it figures things out

**Finding sessions.** `proc_listpids` for the process list, matched on `proc_name`. Claude Code
now ships as a self-extracting binary whose `proc_pidpath` lookup returns nothing, so the comm
field is the reliable identifier. Working directory comes from `PROC_PIDVNODEPATHINFO`, the TTY
from `PROC_PIDTBSDINFO`, and CPU from `proc_pid_rusage` sampled across refreshes.

**Matching a session to its transcript.** Claude Code stores transcripts under
`~/.claude/projects/<mangled-cwd>/<session-id>.jsonl`, but several sessions often share one
working directory, so the directory alone is ambiguous. Resolution runs in three passes:

1. `claude --resume <id>` names its transcript outright — read from the process's argv via
   `KERN_PROCARGS2`.
2. Otherwise, a fresh session writes its transcript shortly after launch, so each process claims
   the unclaimed transcript created soonest *after* its own start time.
3. `claude --continue` reopens an older file, so anything left over falls back to the most
   recently modified unclaimed transcript.

Bindings are sticky once resolved. A session you've launched but not yet prompted has no
transcript at all, and shows up as a ready tile with just its directory.

**Deciding the colour.** The transcript is walked to find tool calls with no matching result. No
pending tool means the turn ended cleanly — green. A pending `AskUserQuestion` or `ExitPlanMode`
is unambiguously blue.

Anything else pending is genuinely ambiguous: "running a long command" and "showing you a
permission prompt" look *identical* in the transcript, because in both cases Claude asked to do
something and no result came back. That tie is broken on behaviour rather than content — if the
process is burning CPU or has written to its transcript in the last 12 seconds it's working
(red), otherwise it's been silent with a request outstanding, which in practice means a prompt
is on your screen (blue). Sessions in `bypassPermissions` mode can't be blocked on approval, so
they stay red.

Sub-agent traffic is excluded from this so it doesn't produce phantom pending calls; a running
sub-agent still shows up as a pending `Task` on the main thread.

**Focusing a tab.** Every session has a distinct TTY, and both Terminal.app and iTerm2 expose a
tab's `tty` to AppleScript, so the exact tab gets raised. Terminals without that scripting
surface (Ghostty, kitty, WezTerm, Alacritty) fall back to activating the application — the host
app is found by walking the process's parent chain until something owns a GUI app.

## Checking it works

```bash
fleet --scan
```

Prints every session it can see, with the transcript it bound, the state it derived and why:

```
6 session(s):

  [READY    ] portfolio  pid=40776  tty=/dev/ttys000  cpu=0.0%
      path:  ~/self/portfolio
      topic: Améliorer fluidité et ajouter effets visuels aux projets
      file:  5f43933c-708c-494e-a199-45419b67b5c6.jsonl

  [WORKING  ] self  pid=33614  tty=/dev/ttys005  cpu=0.3%
      path:  ~/self
      topic: Build idle activity monitor for Claude Code sessions
      file:  ab445216-f7c3-4d8a-b629-4d8255d34755.jsonl
      pending: Bash
```

## Options

`fleet` with no arguments toggles the panel. Anything else is passed to the binary:

| Flag | Effect |
|------|--------|
| `--scan` | print detected sessions and exit |
| `--idle <seconds>` | override the idle threshold (default 150) |
| `--show` | toggle the panel immediately, ignoring the idle timer |
| `--demo` | same as `--show` |
| `--render <path.png>` | draw the panel offscreen to a PNG (how the image above was made) |

Other tunables — poll cadences, the staleness window, the CPU threshold — are all in
`Sources/Fleet/Models.swift`, deliberately in one place so the battery profile is
auditable at a glance.

## Also starting it when Claude Code launches

The LaunchAgent already keeps it running from login onward, which covers this. If you'd rather
it also self-heal whenever you start a session, add a `SessionStart` hook to
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "launchctl kickstart gui/$UID/com.mr.fleet"
          }
        ]
      }
    ]
  }
}
```

`kickstart` starts the agent if it's stopped and does nothing if it's already up. Don't use
`open` here — opening the bundle is the manual "show me the panel" gesture, so a hook that ran
it would put the panel on screen every time you started a session.

## License

MIT
