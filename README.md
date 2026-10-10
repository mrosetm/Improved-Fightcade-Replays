# Improved Fightcade Replays

A Lua script for **Fightcade 2** that adds real **rewind**, **pause**, **frame stepping** and **playback speeds** (0.25x to 4x) to **Street Fighter III: 3rd Strike** replays.

Hold `R` to go back in the match, release it, and the replay continues from that point with the game state and the players' inputs in sync. No restarting the replay.

[![Showcase of the Improved Fightcade Replays LUA (video)](https://img.youtube.com/vi/S5df5cU_WiU/hqdefault.jpg)](https://www.youtube.com/watch?v=S5df5cU_WiU)

*Video showcase by [ArKeynes](https://www.youtube.com/@ArKeynes3136). Click to watch on YouTube.*

> **Status:** 1.0.0. Tested in Fightcade by [ArKeynes](https://www.youtube.com/@ArKeynes3136) (see the video above) and against a simulation of the emulator's frame loop. More reports are welcome; see [Reporting problems](#reporting-problems).

## Features

- **Real rewind**: restores the actual emulated state (positions, health, stun, timer, animations, projectiles) and keeps the replay inputs synchronized afterwards.
- **Keep watching after a rewind**: the replay keeps streaming in the background and is recorded, so you can rewind as often as you like and still watch to the end of the match.
- **Seven speeds**: 0.25x, 0.5x, 1x, 1.25x, 1.5x, 2x, 4x, switchable while the replay runs.
- **Pause and frame-by-frame stepping**, forward and backward.
- **Built-in sync check**: every replayed frame is compared with its first playthrough; the overlay shows `SYNC OK` or `DESYNC at frame N`.
- **Small on-screen overlay** (toggle with `H`).
- Single file, no dependencies.

## Installation

1. Download [`fightcade_replay_controller.lua`](fightcade_replay_controller.lua).
2. Put it in your Fightcade folder under `Fightcade\emulator\fbneo\` (next to `fcadefbneo.exe`). Any folder works; this is just where the file browser opens.

## Usage

1. Start a 3rd Strike replay from the Fightcade lobby.
2. As soon as the picture appears, open **Game › Lua Scripting... › New Lua Script Window...** (or press `Alt+L`).
3. Click **Browse...**, pick `fightcade_replay_controller.lua`, then click **Run**.

You can only rewind back to the moment the script started, so start it early in the replay.

### Controls

| Key | Action |
|---|---|
| `R` (hold) | Rewind; release to resume from there. `Shift+R` rewinds faster. |
| `Space` | Pause / resume |
| `Left` / `Right` | Step one frame back / forward (pauses first; hold to repeat) |
| `1` – `7` | 0.25x, 0.5x, 1x, 1.25x, 1.5x, 2x, 4x |
| `N` | Back to 1x |
| `H` | Hide / show the overlay |
| `Alt+1` | Detach from the replay stream (see [Limitations](#limitations)) |

The overlay shows the state (PLAY, PAUSE, REWIND, FAST-FORWARD), speed, frame number and time, how far back you can rewind, and the sync status.

## Configuration

Optional. Settings are in the `CONFIG` table at the top of the script.

| Setting | Default | Meaning |
|---|---|---|
| `BACKEND` | `"mem"` | `"mem"`: fast in-memory snapshots. `"file"`: complete snapshots on disk (no graphics glitches after rewinding), with a short hitch each time one is written. |
| `CHECKPOINT_INTERVAL` | `10` | Frames between snapshots (`mem`). |
| `FILE_CHECKPOINT_INTERVAL` | `60` | Frames between snapshots (`file`). |
| `FILE_MAX_CHECKPOINTS` | `240` | Number of snapshot files kept (`file`). |
| `REWIND_SPEED` / `REWIND_SPEED_FAST` | `3` / `10` | Rewind speed as a multiple of real time. |
| `VERIFY_SYNC` | `true` | Enable the sync check. |
| `OVERLAY`, `OVERLAY_X`, `OVERLAY_Y` | `true`, `4`, `34` | Overlay visibility and position. |

## How it works

A Fightcade replay is a GGPO spectator session: each emulated frame pulls the next input from a stream that only moves forward. Loading a save state on its own rewinds the game, but the stream keeps going, so inputs and state drift apart.

This script:

1. Records every input from the replay stream, indexed by frame.
2. Saves a snapshot every few frames with `savestate.save_mem`, a Fightcade-specific in-memory save state.
3. On rewind, loads a snapshot and, from then on, overrides the inputs with `joypad.set` using the recorded input for the frame actually being emulated. The stream keeps flowing and keeps being recorded ahead of what you see.
4. Pauses and slow motion by re-emulating the same frame from a snapshot (the emulator's own pause also stops Lua scripts).
5. Runs faster than 1x by switching the emulator's turbo mode on and off against a wall-clock budget, so the average speed is exact.
6. Fingerprints 3rd Strike RAM (game frame counter and both player structures) every frame to detect any desync.

## Limitations

- **Rewind starts when the script starts.** Earlier frames are not available.
- **Possible brief graphics glitches** (`mem` backend): `save_mem` does not store the colour palette or the 8 MB CPS3 character RAM. Gameplay is restored exactly, but right after a long rewind a few frames may show wrong colours or sprite tiles. Use `BACKEND = "file"` to avoid this.
- **History length:** Fightcade keeps at most 4,096 in-memory snapshots (about 11 minutes at the default interval). Older ones are recycled automatically. Pause and slow motion use extra snapshots, which shortens the history.
- **Speeds above 1x** come from Fightcade's turbo mode (about 11 frames per screen update), so most frames display normally with periodic jumps of about 10 frames.
- **Audio** repeats a short fragment while paused or in slow motion.
- **Keys are read globally**, so typing in another window also triggers the controls.
- **End of the replay:** if you are behind (after rewinding or pausing) when the replay data runs out, the picture freezes and scripts stop running. Press `Alt+1` to detach; you can then keep watching and rewinding everything already recorded. What Fightcade does at the end of a replay could not be confirmed from the public source.
- The sync check is 3rd Strike-specific; on other games the script still runs but reports no sync status.

## Testing

**Real-world testing:** done by [ArKeynes](https://www.youtube.com/@ArKeynes3136), who ran the script in Fightcade and recorded a [video showcase](https://www.youtube.com/watch?v=S5df5cU_WiU) of its features. Wider testing on other setups is still welcome (see [Reporting problems](#reporting-problems)).

### In Fightcade

1. Load the script at the start of a replay. The Lua console should print `source: replay stream ... sync check: on`.
2. Let it play about 30 s, hold `R` for 3 s and release. Playback should continue from the earlier point.
3. Watch through the moment where you started rewinding. The overlay should say `SYNC OK`, and health, positions and timer should match the first viewing.
4. Repeat rewind/resume 5–10 times, then try keys `1` to `7` and `N`.
5. Pause with `Space`, then press `Right` and `Left`: the frame number should change by exactly 1 each time.
6. During a long replay, watch `fcadefbneo.exe` memory in Task Manager.

### Automated tests

`tests/mock_fightcade.lua` simulates the FightcadeFBNeo frame loop: replay input stream, Lua `before` hook and `joypad.set` override order, the 4,096-slot `save_mem` ring, turbo bursts and a wall clock. It checks that the emulated state matches a reference timeline on every frame, and covers rewind/resume cycles, all seven speeds, pause and stepping, snapshot recycling, stream end and detach. It also runs the script in a sandbox that fails on accidental global variables.

It needs a Lua 5.1 interpreter (the version FightcadeFBNeo embeds):

```sh
lua5.1 tests/mock_fightcade.lua fightcade_replay_controller.lua
```

Exit code `0` means every check passed. `STREAM_LEN=<frames>` changes the simulated replay length (default 50,000).

## Reporting problems

Please open an issue with:

- your Fightcade version,
- what the overlay showed (especially any `DESYNC at frame N` message, and what was happening on screen),
- the memory usage of `fcadefbneo.exe` if it grew large or crashed,
- any error shown in the Lua console.

## Credits

- Lua API, replay pipeline and save-state behaviour taken from the [FightcadeFBNeo source](https://github.com/fightcadeorg/fightcade-fbneo).
- 3rd Strike RAM addresses from [Grouflon/3rd_training_lua](https://github.com/Grouflon/3rd_training_lua).
- Replay detection and `emu.takeover()` usage informed by [peon2/fbneo-training-mode](https://github.com/peon2/fbneo-training-mode).

## Use of AI

This project was written with the help of an AI model, Claude Opus 5.5 by Anthropic

## License

Copyright (C) 2026 fightcade-replay-controller contributors.

This project is free software under the [GNU General Public License v3.0 or later](LICENSE). You may use, study, share and modify it. If you distribute it or a modified version, you must release it under the same license with its source code.
