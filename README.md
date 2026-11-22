# Herdr Board · v2.8

A Windows terminal dashboard for Herdr. It shows agent roles and activity, available quota, active work, and tasks completed in the last 24 hours. The background view shows running jobs and their latest steps.

![Herdr Board v2.8 with synthetic example data](docs/demo.png)

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
.\bg-view.ps1 -LogRoot .\logs
~~~

`LogRoot` contains local backlog and worker files. To manage the backlog, run `.\backlog.ps1 -Add "Check the sample" -Owner Codex -State working`, then `.\backlog.ps1 -Done <id>` with the returned ID. Use a card named `card-<id>.md` with a `기기: Remote Lab` line to show a device tag.

Quota displays when compatible local captures are present. The included `claude-status.mjs` can be used as a Claude Code status-line command with Node.js. Its default output file is `logs/claude-usage.json`. Set `CLAUDE_STATUS_CAPTURE` to use another path and point `ClaudeUsageFile` there. `AgyUsageFile` accepts quota buckets with `remaining_fraction` and `reset_time`. `CodexSessionsPath` points to local Codex rollout files. Keep local configuration and runtime data private. Use `-Demo` when sharing a screenshot.

Run `.\verify-board-matrix.ps1` to test the renderers against sample layouts and mock data.

## 한국어

Herdr의 에이전트, 사용량, 진행 작업과 최근 24시간 완료 작업을 터미널에서 확인할 수 있습니다. `.\board.ps1 -Demo`로 예제를, `.\bg-view.ps1 -Demo`로 백그라운드 보기를 엽니다. 실사용 시 설정 예시를 복사하고 세션의 창 ID와 로그 경로를 입력합니다.

[MIT License](LICENSE)
