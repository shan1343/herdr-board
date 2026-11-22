# Herdr Board · v2.9

A Windows terminal dashboard for Herdr. It shows agent roles and activity, available quota, active work, and tasks completed in the last 24 hours. The background view shows running jobs and their latest steps.

![Herdr Board v2.9 with synthetic example data](docs/demo.png)

## Run the demo

Use Windows PowerShell 5.1 or PowerShell 7 in a terminal with ANSI color support.

~~~powershell
.\board.ps1 -Demo
.\bg-view.ps1 -Demo
~~~

Add `-Once` for a single frame, or press Ctrl+C to stop the refreshing view. The screenshot was generated using `board.ps1 -Demo -Once -Width 86 -Height 30`.

## Use a live session

1. Start [Herdr](https://herdr.dev/) and copy `board.config.json` to `board.local.config.json`.
2. Run `herdr pane list` in the session and replace the example pane IDs in `Agents`. Each entry has a `Pane`, `Key` (platform), `Name`, and `Role`. Use `claude`, `codex`, or `agy` for `Key`. Multiple sessions can use the same platform.
3. Set the optional `Session` name or provide a socket through `HerdrSocketPath`. An existing `HERDR_SOCKET_PATH` takes precedence. File paths are relative to the configuration file and support `%ENV_VAR%` placeholders.

~~~powershell
.\board.ps1 -ConfigPath .\board.local.config.json
.\bg-view.ps1 -Session example-session -LogRoot .\logs\room
~~~

Each session should use its own `LogRoot` for the backlog and worker files. Pass the same root and session to both views. The sample uses `logs/room` for the named session and `logs` for shared files. Set `SharedLogRoot` in the board configuration and pass `-SharedLogRoot` to the background view if you move the shared root.

For a shared `exec-<id>.jsonl`, add `작업실: example-session` to the matching `card-<id>.md` in the same directory. The views can also use a worker's session or working directory, including the directory in a local Codex session record. To map project directories, set `Name` and an absolute `ProjectPath` in `spaces/<room>/effective-space.json`. That room's Herdr session name is `space-<room>`. Shared jobs without ownership information appear in the default Work session.

Run `./backlog.ps1 -LogRoot ./logs/room -Add "Check the sample" -Owner Codex -State working`, then `./backlog.ps1 -LogRoot ./logs/room -Done <id>` with the returned ID. Add `기기: Remote Lab` to a card to show a device tag.

Quota displays when compatible local captures are present. The included `claude-status.mjs` can be used as a Claude Code status-line command with Node.js. Its default output file is `logs/claude-usage.json`. Set `CLAUDE_STATUS_CAPTURE` to use another path and point `ClaudeUsageFile` there. `AgyUsageFile` accepts quota buckets with `remaining_fraction` and `reset_time`. `CodexSessionsPath` points to local Codex rollout files. Keep local configuration and runtime data private. Use `-Demo` when sharing a screenshot.

Run `.\verify-board-scope.ps1` for worker isolation and `.\verify-board-matrix.ps1` for layout checks.

## 한국어

Herdr의 에이전트, 사용량, 진행 작업과 최근 24시간 완료 작업을 터미널에서 확인할 수 있습니다. `.\board.ps1 -Demo`로 예제를, `.\bg-view.ps1 -Demo`로 백그라운드 보기를 엽니다. 실사용 시 작업실별 로그 폴더를 지정하고 두 보기에 같은 세션과 로그 경로를 사용합니다. 공용 로그는 카드의 작업실 표시, 실행 기록의 작업 경로, 또는 세션 정보로 분류합니다.

[MIT License](LICENSE)
