# Bubblegum

**Run several Claude Code sessions side by side in one Mac window, and always know which one needs you.**

Each session is a real terminal running `claude` in a project folder. Bubblegum names it, shows its live
status (Working, Needs you, Your turn), notifies you when Claude finishes or asks for permission, and keeps
the list tidy with search, rename and archive.

**[⬇ Download Bubblegum for Mac](https://github.com/ysafr7/bubblegum-terminal/releases/latest/download/Bubblegum.dmg)**
· version 0.3.0 · macOS 14 Sonoma or later · Apple Silicon and Intel ·
[all releases](https://github.com/ysafr7/bubblegum-terminal/releases)

## Features

- **Many sessions, one window.** Each session keeps running while you switch; scrollback stays intact.
- **Live status from Claude Code's hooks.** Working, Needs you, Your turn, Ended: in the sidebar and the header.
- **Notifications and a Dock badge** when a session you're not looking at finishes or needs an answer.
- **Model and effort** of the last answer in the header, e.g. *Opus 5.5 · High effort*.
- **Session Info** (⌘I, or right-click a session): model and effort, when it started, active time, and token use (input, output, cache read, subagents included).
- **Branch switcher** in the toolbar: see the session folder's git branch and uncommitted changes, search local and remote branches, switch, or create a new branch.
- **New session sheet** (⌘T): open a project folder, start a blank session, or reopen one of your recent projects with ⌘1–⌘9.
- **Session groups:** sort sessions into named, coloured groups. Collapse a group and a dot still tells you when a session in it needs you. Drag sessions between groups, reorder them, or drag groups to reorder; start a new session straight into a group from its menu.
- **Organize:** rename (click away to save), archive, delete; search all sessions (⌘F) or jump to one with the quick switcher (⌘K).
- **Export** a session's whole conversation as a Markdown file (⇧⌘E).
- **Resumes where you left off:** after a restart, opening a session continues its conversation (`claude --resume`).
- **Dark and light themes**, adjustable terminal font size.
- **Local only:** no account, no backend, no telemetry. Bubblegum makes no network requests.

## Install

1. [Download `Bubblegum.dmg`](https://github.com/ysafr7/bubblegum-terminal/releases/latest/download/Bubblegum.dmg), open it, and drag **Bubblegum** to **Applications**.
2. **First launch only:** this build isn't notarized by Apple yet, so macOS blocks it the first time.
   Open Bubblegum once, then go to **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Bubblegum.app`.)
3. When Bubblegum asks, click **Install hooks**. This lets it see when Claude is working, needs you, or is done
   (it adds four entries to `~/.claude/settings.json` and backs the file up first).

You need [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and working in your terminal
(`claude` on your PATH). Bubblegum starts it through your login shell, so your `~/.zshrc` setup applies.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T | New session (project, blank or recent) |
| ⌘O / ⌘N | Open project… / Blank session |
| ⌘K | Quick switcher |
| ⌘F | Search sessions |
| ⌘1 … ⌘9 | Select a session (or open a recent project in the New session sheet) |
| ⇧⌘] / ⇧⌘[ | Next / previous session |
| ⌘R | Rename |
| ⌘I | Session Info |
| ⇧⌘A | Archive / unarchive |
| ⇧⌘E | Export session as Markdown |
| ⌘+ / ⌘− / ⌘0 | Terminal font size |
| ⌘, | Settings |

## Your data

- Bubblegum keeps its session list in `~/Library/Application Support/Bubblegum/` (`sessions.json`, `recents.json`). If `sessions.json` can't be read, it is copied to `sessions.json.unreadable-<date>` before being replaced, so nothing is lost.
- Conversations are stored by Claude Code itself in `~/.claude/projects/`; Bubblegum only reads them (to resume,
  show the model, and export). Deleting a session in Bubblegum never deletes Claude's transcript.
- Uninstall: delete the app and that folder, and remove the `Bubblegum/hook.sh` entries from `~/.claude/settings.json`.

---

## Development

### Build and run

Requires Xcode 15+ installed (SwiftUI's macros ship with Xcode, not with the Command Line Tools alone).

```sh
scripts/run.sh                  # debug build of the .app, then launch it (use this rather than Run in Xcode)
scripts/test.sh                 # unit tests
scripts/build-app.sh            # → build/Bubblegum.app (release, universal, ad-hoc signed)
scripts/make-dmg.sh             # → build/Bubblegum-<version>.dmg and build/Bubblegum.dmg (+ .sha256)
```

Run the app as a bundle (`scripts/run.sh`), not with Xcode's Run button: Xcode launches the bare
SwiftPM executable, which has no Info.plist or asset catalog, so menus and controls fall back to system
blue instead of the brand pink, and notifications are unavailable. (macOS also uses the user's own accent
colour when one is picked in System Settings › Appearance; with Multicolor, the default, apps get theirs.)

The scripts set `DEVELOPER_DIR` to `/Applications/Xcode.app` automatically if `xcode-select`
points at the Command Line Tools. For an Xcode project: `xcodegen generate` (uses `project.yml`).

The version lives in `Sources/BubblegumCore/AppVersion.swift` (and `Resources/Info.plist`; a test keeps them in sync).

### Layout

| Path | What |
| --- | --- |
| `Sources/BubblegumCore` | UI-free logic: `Session`/statuses, hook installer + settings merge, hook event parsing and status reducer, event folder watcher, sidebar grouping/search, recent projects, transcript reading/export, launch command, persistence |
| `Sources/Bubblegum/Services` | `SessionStore` (source of truth), `TerminalRegistry` (one cached terminal per session), `Notifier`, `AppSettings` |
| `Sources/Bubblegum/Views` | Sidebar, rows, detail header + terminal host, quick switcher, new session sheet, settings, hook sheet |
| `Sources/Bubblegum/Theme` | Dark/light design tokens (spec §8) — views never use raw hex |
| `Resources` | `Info.plist`, `Assets.xcassets` (AppIcon generated by `scripts/make-icon.swift`, AccentColor) |

### Files on disk

- `~/Library/Application Support/Bubblegum/sessions.json` — sessions (atomic writes)
- `~/Library/Application Support/Bubblegum/recents.json` — recent projects
- `~/Library/Application Support/Bubblegum/hook.sh` — hook script (no-op unless `BUBBLEGUM_SESSION_ID` is set)
- `~/Library/Application Support/Bubblegum/events/` — transient hook events
- `~/.claude/settings.json` — hook entries merged in on "Install hooks"; backed up to `settings.json.bubblegum-backup` first

### Development aids (debug builds)

- `BUBBLEGUM_SUPPORT_DIR=/some/dir` uses another folder for sessions/events instead of Application Support;
  "Install hooks" then writes to `/some/dir/claude/settings.json` (or `BUBBLEGUM_CLAUDE_DIR`), never the real `~/.claude`.
- `BUBBLEGUM_SNAPSHOT=/tmp/shot BUBBLEGUM_SNAPSHOT_STEPS=main,switcher,clear,search,rename,info,light` renders window snapshots, then quits.

## License

[MIT](LICENSE) © 2026 Eugene Safronov.

Bubblegum uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT); its license is in its repository.
