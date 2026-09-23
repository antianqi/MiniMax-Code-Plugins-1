# Hook: PostToolUse
# Event:  io.minimax.mcode / PostToolUse
# State:  done / error
# Note:   Fires after every tool call returns. Heuristic: if the
#         tool_result is empty or matches an error pattern, push
#         error; otherwise push done. Self-push calls are filtered.
#         Per-tool summary (Format-ToolSummary) is split into
#         Message="<tool> ok|failed" and Detail=<the rest>, so the pill
#         renders "Bash ok · ls -la /tmp" instead of just "Bash ok".
. "$PSScriptRoot\_lib.ps1"
$evt = Read-HookStdin
if (Test-IsSelfPush $evt) { exit 0 }

$tool  = if ($evt.tool_name) { [string]$evt.tool_name } else { 'tool' }
$result = $evt.tool_result
$isError = $false

if ($null -eq $result) {
    $isError = $true
} else {
    $s = [string]$result
    if ([string]::IsNullOrEmpty($s)) { $isError = $true }
    elseif ($s -match '^\s*(Error|ERROR|✕|Error:|\[ERROR\])') { $isError = $true }
}

# Format-ToolSummary 抽 detail,但要剥掉 "tool : " 前缀,只留后半段
$summary = Format-ToolSummary $evt
$detail = ''
if ($summary -and $summary.StartsWith("$tool : ")) {
    $detail = $summary.Substring($tool.Length + 3)
} elseif ($summary -and $summary -ne $tool) {
    $detail = $summary
}

if ($isError) {
    Push-Island -State error -Message "$tool failed" -Detail $detail
} else {
    Push-Island -State done -Message "$tool ok" -Detail $detail
}
exit 0
