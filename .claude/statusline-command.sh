#!/bin/bash
# Claude Code statusLine command
# Displays: cwd | git repo | model | context usage | estimated cost | rate limits

input=$(cat)

# Current working directory (shortened)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
if [ -n "$cwd" ]; then
  home="$HOME"
  cwd="${cwd/#$home/~}"
fi

# Git repo info
repo=$(echo "$input" | jq -r '.workspace.repo | if . then .owner + "/" + .name else empty end')

# Git worktree info
worktree=$(echo "$input" | jq -r '.workspace.git_worktree // empty')

# Model display name and model ID
model=$(echo "$input" | jq -r '.model.display_name // empty')
model_id=$(echo "$input" | jq -r '.model.id // empty')

# Context window info
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Token usage for cost estimation (use cumulative session totals)
cache_write=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
output_tokens=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')

# Cumulative totals across the session for more accurate cost display
total_input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

# PR info
pr_number=$(echo "$input" | jq -r '.pr.number // empty')
pr_state=$(echo "$input" | jq -r '.pr.review_state // empty')

# Rate limits
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')

# Estimate cost based on model ID (USD per 1M tokens)
# Pricing reference: claude-sonnet-4 class models
estimate_cost() {
  local mid="$1"
  local inp="$2"
  local out="$3"
  local cw="$4"
  local cr="$5"

  # Default pricing (claude-sonnet-4 / sonnet-4-5 / sonnet-4-6)
  local in_price=3.0
  local out_price=15.0
  local cw_price=3.75
  local cr_price=0.30

  # Adjust pricing by model family
  case "$mid" in
    *haiku*)
      in_price=0.80; out_price=4.0; cw_price=1.0; cr_price=0.08 ;;
    *opus*)
      in_price=15.0; out_price=75.0; cw_price=18.75; cr_price=1.50 ;;
    *sonnet*)
      in_price=3.0; out_price=15.0; cw_price=3.75; cr_price=0.30 ;;
  esac

  # Cost in USD = tokens / 1,000,000 * price
  awk -v inp="$inp" -v out="$out" -v cw="$cw" -v cr="$cr" \
      -v ip="$in_price" -v op="$out_price" -v cwp="$cw_price" -v crp="$cr_price" \
    'BEGIN {
      cost = (inp/1000000*ip) + (out/1000000*op) + (cw/1000000*cwp) + (cr/1000000*crp)
      if (cost < 0.001) printf "< $0.001"
      else if (cost < 1.0) printf "$%.3f", cost
      else printf "$%.2f", cost
    }'
}

# Build output parts
parts=()

# Directory part
if [ -n "$cwd" ]; then
  parts+=("$(printf '\033[1;34m%s\033[0m' "$cwd")")
fi

# Repo/branch part
if [ -n "$repo" ]; then
  repo_str="$repo"
  [ -n "$worktree" ] && repo_str="$repo_str [$worktree]"
  parts+=("$(printf '\033[1;36m%s\033[0m' "$repo_str")")
elif [ -n "$worktree" ]; then
  parts+=("$(printf '\033[1;36m[%s]\033[0m' "$worktree")")
fi

# PR part
if [ -n "$pr_number" ]; then
  pr_str="PR #$pr_number"
  [ -n "$pr_state" ] && pr_str="$pr_str ($pr_state)"
  parts+=("$(printf '\033[1;35m%s\033[0m' "$pr_str")")
fi

# Model part
if [ -n "$model" ]; then
  parts+=("$(printf '\033[0;33m%s\033[0m' "$model")")
fi

# Context remaining part: show used/total tokens and percentage
if [ -n "$remaining" ] && [ "$context_size" -gt 0 ] 2>/dev/null; then
  remaining_int=$(printf '%.0f' "$remaining")
  used_int=$(printf '%.0f' "${used:-0}")

  # Format token counts (e.g. 45k / 200k)
  fmt_tokens() {
    awk -v n="$1" 'BEGIN {
      if (n >= 1000000) printf "%.1fM", n/1000000
      else if (n >= 1000) printf "%.0fk", n/1000
      else printf "%d", n
    }'
  }
  used_fmt=$(fmt_tokens "$total_input")
  total_fmt=$(fmt_tokens "$context_size")

  if [ "$remaining_int" -le 20 ]; then
    ctx_color='\033[1;31m'
  elif [ "$remaining_int" -le 50 ]; then
    ctx_color='\033[1;33m'
  else
    ctx_color='\033[0;32m'
  fi
  parts+=("$(printf "${ctx_color}ctx:%s/%s(%d%%)\033[0m" "$used_fmt" "$total_fmt" "$remaining_int")")
elif [ -n "$remaining" ]; then
  remaining_int=$(printf '%.0f' "$remaining")
  if [ "$remaining_int" -le 20 ]; then
    ctx_color='\033[1;31m'
  elif [ "$remaining_int" -le 50 ]; then
    ctx_color='\033[1;33m'
  else
    ctx_color='\033[0;32m'
  fi
  parts+=("$(printf "${ctx_color}ctx:%d%%\033[0m" "$remaining_int")")
fi

# Cost estimation part (only when there has been at least one API call)
# Uses total session input/output tokens for cumulative cost display
has_usage=$(echo "$input" | jq -r '.context_window.current_usage | if . then "yes" else "no" end')
if [ "$has_usage" = "yes" ]; then
  cost_str=$(estimate_cost "$model_id" "$total_input_tokens" "$total_output_tokens" "$cache_write" "$cache_read")
  parts+=("$(printf '\033[0;36mcost:%s\033[0m' "$cost_str")")
fi

# Rate limit part
if [ -n "$five_hour" ]; then
  five_int=$(printf '%.0f' "$five_hour")
  parts+=("$(printf '\033[0;90m5h-limit:%d%%\033[0m' "$five_int")")
fi

# Join parts with separator
printf '%s' "${parts[0]}"
for part in "${parts[@]:1}"; do
  printf ' \033[0;90m|\033[0m %s' "$part"
done
printf '\n'
