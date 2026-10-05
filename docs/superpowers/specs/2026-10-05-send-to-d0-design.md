# Design: Send text commands to D0

## Context
zsm currently only receives. `Port` opens the device read/write (`src/port.zig:41`) but never writes. You want to type text commands (AT commands, CLI/debug commands) and send them to device **D0 only**, with the replies showing up in the same log.

**Agreed requirements (from you):**
- Text commands, one line at a time (no live keystrokes, no hex input).
- A key opens a one-line input bar. Enter sends and keeps the bar open; Esc closes it. The hotkeys keep working while it's closed.
- The line ending is selectable (`\r\n`, `\n`, `\r`, none), starting at `\r\n`.
- Sent commands are echoed in the log as TX lines and included in copy and export.
- ↑/↓ history, saved across sessions.
- The write happens directly on the UI thread when Enter is pressed (no writer thread).

**Defaults (approved with the design):**
- The key that opens the bar is `s`, and Tab cycles the line ending while the bar is open.
- History keeps the last 200 entries, skipping empty commands and repeats of the previous one.
- The ending choice is not persisted; it resets to `\r\n` each start.

## Behaviour
- **Opening the bar:** `s` opens it whether or not D0 is connected. If D0 isn't connected, the bar's label says so and Enter shows `send: D0 not connected` in the top bar.
- **Layout:** the bar sits between the log/inspector and the footer, one row high:
  `D0 ❯ AT+GMR█                                   [\r\n]`
- **Keys while the bar is open:**
  - Enter: send `text + ending`, echo it to the log, add it to history, clear the input.
  - Tab: cycle `\r\n → \n → \r → none`.
  - ↑/↓: walk through history; whatever you were typing comes back after the newest entry.
  - Esc: close the bar.
  - Editing keys work as in the export prompt (`vxfw.TextField`).
  - All other hotkeys (`o`, `c`, `e`, `f`, Tab view toggle, list ↑/↓) are suppressed. `Ctrl+C` still quits, `Ctrl+Shift+C` still copies, and mouse selection still works.
- **Echo:** a TX line uses port 0, a send timestamp, the command text and the chosen ending. It renders as `12:00:01.100 [D0] → AT+GMR \r\n`, with `→` and the body in the accent style so it stands apart from device replies. The inspector works on it like on any other line.
- **Bottom-bar hints** while the bar is open: `Enter send │ Tab ending │ ↑↓ history │ Esc close`. When it's closed, an `s send` hint is added.
- **Export:** a new `dir` column (`rx`/`tx`) goes after `port`.

## Components
1. **`Port.write(bytes)`** in `src/port.zig`: a blocking write-all loop.
   - Windows: `extern "kernel32" fn WriteFile`, next to the existing `ReadFile` extern. It may wait up to 100 ms behind the reader's pending `ReadFile` (same non-overlapped handle). That's accepted.
   - POSIX: loop over `std.posix.write`.
   - On error it returns the error; it does not mark the port errored (the reader thread owns that).
2. **`types.Line.direction: enum { rx, tx } = .rx`** in `src/types.zig`. RX lines are unchanged.
3. **`src/send_bar.zig`** (new), modelled on `SavePrompt` (`src/save_prompt.zig`):
   - It owns the `vxfw.TextField`, the current `Terminator` and the history.
   - `handleKey` returns `consumed | ignored | close | send`, mirroring `SavePrompt.KeyResult`.
   - It draws the one-row bar, painting a block cursor the same way `SavePrompt.drawInner` does.
   - Pure helpers live at the top of the file with unit tests: the history ring (push with dedupe and cap, walking ↑/↓), parsing and serialising the history file, and the ending cycle.
4. **History persistence** (inside `send_bar.zig`):
   - File location: `%APPDATA%\zsm\history.txt` on Windows, `~/Library/Application Support/zsm/history.txt` on macOS, `$XDG_STATE_HOME/zsm/history.txt` on Linux (falling back to `~/.local/state/zsm/history.txt`).
   - One command per line. It's loaded on start and rewritten after each send.
   - Failures are silent: history then works in memory only.
   - The environment map is passed from `main.zig` → `App.init` → `Monitor.init` → `SendBar.init`.
5. **Monitor wiring** in `src/monitor.zig`:
   - `send_bar_open` flag; `handleKey` routes keys to the bar first (like `save_prompt_open`).
   - `drawMain` reserves a row for the bar.
   - `sendToD0()` calls `ports[0].write`, then `appendLine` with a `.tx` line whose text is duped like RX lines.
   - On failure it shows the error in the top bar via `setExportMessage`.
6. **Rendering** in `src/line_render.zig` / `drawLineFn`: TX lines get the `→` marker and the accent body style in all three display modes.
7. **Export** in `src/export.zig`: add the `dir` column and update its tests.

## Error handling
- D0 not connected → message in the top bar, nothing echoed.
- Write error → message in the top bar, nothing echoed, input kept so you can retry.
- History file unreadable or unwritable → ignored.

## Testing
- Unit tests:
  - history: dedupe, cap, ↑/↓ walk and restoring your draft
  - history file round-trip
  - ending cycle
  - export `dir` column
  - TX line rendering text, via `selection.flattenRow` + `appendCellText`
- Manual check on Windows against a device that answers (or a USB-UART loopback with TX tied to RX):
  - send with each line ending
  - check the echo order next to the replies
  - ↑/↓ history after restarting zsm
  - the error message when D0 is closed
  - hotkeys behave normally after Esc
- `zig build` and `zig build test` must pass.

