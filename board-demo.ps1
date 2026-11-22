function Get-BoardDemo([DateTimeOffset]$Now) {
    $sessions=@(
        [pscustomobject]@{Id='claude';Kind='claude';Role='지휘';Pane='demo-claude'}
        [pscustomobject]@{Id='codex';Kind='codex';Role='구현';Pane='demo-codex'}
        [pscustomobject]@{Id='codex-2';Kind='codex';Role='검토';Pane='demo-codex-2'}
        [pscustomobject]@{Id='agy';Kind='agy';Role='조사';Pane='demo-agy'}
    )
    [pscustomobject]@{
        Sessions=$sessions
        Agents=@(foreach($session in $sessions){
            [pscustomobject]@{pane_id=$session.Pane;agent_status=if($session.Id -eq 'codex'){'working'}else{'idle'}}
        })
        Workers=[pscustomobject]@{
            Available=$true
            Active=@(
                [pscustomobject]@{Agent='codex';Title='검색 필터 추가';Minutes=4;Model='gpt-6.2-sol';Effort='medium';Device=@{Name='Remote Lab'}}
                [pscustomobject]@{Agent='claude';Title='예제 코드 검토';Minutes=2;Model='opus';Effort='high'}
            )
        }
        Backlog='| 4 | 후속 검토 | Claude | queued |
| 3 | 일정 확정 | 사용자 | to do |
| 2 | 검색 필터 추가 | Codex | working |'
        Done="| 1 | 예제 데이터 만들기 | Claude | 완료 | $($Now.AddMinutes(-5).ToString('o')) |"
        Usage=@(
            [pscustomobject]@{Id='claude';Model='Claude Opus 5.5';Effort='High';FiveLeft=39;FiveReset=$now.AddMinutes(88);WeekLeft=85;WeekReset=$now.AddHours(91.5)}
            [pscustomobject]@{Id='codex';Account='codex-demo';Model='gpt-6.2-sol';Effort='medium';FiveLeft=50;FiveReset=$Now.AddMinutes(37);WeekLeft=72;WeekReset=$Now.AddMinutes(88)}
            [pscustomobject]@{Id='codex-2';Account='codex-demo';Model='gpt-6.2-sol';Effort='XHIGH';FiveLeft=50;FiveReset=$Now.AddMinutes(37);WeekLeft=72;WeekReset=$Now.AddMinutes(88)}
            [pscustomobject]@{Id='agy';Model='Gemini 4 Neon (High)';FiveLeft=20;FiveReset=$now.AddMinutes(60);WeekLeft=19}
        )
    }
}
