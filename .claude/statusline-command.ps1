# Claude Code statusline script for Windows (no jq required)
# Reads JSON from stdin and outputs a colored status line
# Displays: model name | directory | context usage % | git branch

$input_json = $null
try {
    # Try reading via pipeline input first (works when stdin is a pipe)
    $lines = @($input)
    if ($lines.Count -gt 0 -and $lines[0] -ne $null) {
        $input_json = $lines -join "`n"
    }
} catch {}
if (-not $input_json) {
    try {
        $input_json = [Console]::In.ReadToEnd()
    } catch {}
}
if (-not $input_json) { $input_json = "" }

# ANSI color codes (Windows 10 1511+ supports VT sequences natively)
$ESC     = [char]27
$RESET   = "$ESC[0m"
$CYAN    = "$ESC[96m"
$YELLOW  = "$ESC[93m"
$GREEN   = "$ESC[92m"
$MAGENTA = "$ESC[95m"
$DIM     = "$ESC[2m"
$RED     = "$ESC[91m"

# --- Parse fields via regex (no jq needed) ---

# Model display name (first "display_name" field in JSON)
$model = ""
if ($input_json -match '"display_name"\s*:\s*"([^"]+)"') {
    $model = $Matches[1]
}

# Current working directory (prefer workspace.current_dir, fall back to cwd)
$cwd = ""
if ($input_json -match '"current_dir"\s*:\s*"([^"]+)"') {
    $cwd = $Matches[1] -replace '\\\\', '\'
} elseif ($input_json -match '"cwd"\s*:\s*"([^"]+)"') {
    $cwd = $Matches[1] -replace '\\\\', '\'
}

# Shorten path to last 2 segments for display
$cwd_display = $cwd
if ($cwd_display -ne "") {
    $segs = $cwd_display -split '[/\\]' | Where-Object { $_ -ne "" }
    if ($segs.Count -gt 2) {
        $cwd_display = "...\" + ($segs[-2..-1] -join "\")
    }
}

# Context used percentage (pre-calculated field in JSON)
$ctx_color = $DIM
$ctx_str   = "-"
if ($input_json -match '"used_percentage"\s*:\s*([0-9]+(?:\.[0-9]+)?)') {
    $pct = [int][math]::Round([double]$Matches[1])
    $ctx_str = "${pct}%"
    if      ($pct -lt 50) { $ctx_color = $GREEN  }
    elseif  ($pct -lt 80) { $ctx_color = $YELLOW }
    else                   { $ctx_color = $RED    }
}

# Git branch (--no-optional-locks prevents stalling on lock files)
$git_str = ""
if ($cwd -ne "") {
    try {
        $branch = (& git -C "$cwd" --no-optional-locks branch --show-current 2>$null)
        if ($LASTEXITCODE -eq 0 -and $branch) {
            $branch = $branch.Trim()
            $git_str = "  ${DIM}on${RESET} ${MAGENTA}${branch}${RESET}"
        }
    } catch {}
}

# --- Assemble and print status line ---
$line = ""
if ($model       -ne "") { $line += "${CYAN}${model}${RESET}" }
if ($cwd_display -ne "") { $line += "  ${DIM}in${RESET} ${YELLOW}${cwd_display}${RESET}" }
$line += $git_str
$line += "  ${DIM}ctx${RESET} ${ctx_color}${ctx_str}${RESET}"

Write-Host $line -NoNewline
