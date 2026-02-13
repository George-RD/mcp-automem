#!/bin/bash

# Capture Git Workflow Hook for AutoMem
# Records git commits, GitHub issues, and PR merges with importance tiering

# Conditional success output (only on clean exit)
SCRIPT_SUCCESS=false
trap '[ "$SCRIPT_SUCCESS" = true ] && echo "Success"' EXIT

LOG_FILE="$HOME/.claude/logs/git-workflow.log"
MEMORY_QUEUE="$HOME/.claude/scripts/memory-queue.jsonl"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$MEMORY_QUEUE")"

# Log function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check required dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not installed - git workflow capture disabled" >&2
    exit 0
fi
if ! command -v perl >/dev/null 2>&1; then
    echo "Warning: perl not installed - git workflow capture disabled" >&2
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 not installed - git workflow capture disabled" >&2
    exit 0
fi

# Read JSON input from stdin (Claude Code hook format per docs)
INPUT_JSON=$(cat)
EXIT_CODE="${CLAUDE_EXIT_CODE:-0}"

# Skip failed commands to avoid recording stale state
if [ "$EXIT_CODE" -ne 0 ]; then
    exit 0
fi

# Parse JSON fields using jq
COMMAND=$(echo "$INPUT_JSON" | jq -r '.tool_input.command // ""')
OUTPUT=$(echo "$INPUT_JSON" | jq -r '.tool_response // ""')
CWD=$(echo "$INPUT_JSON" | jq -r '.cwd // ""')
PROJECT_NAME=$(basename "${CWD:-$(pwd)}")

# Skip if not a git/gh command
if [ -z "$COMMAND" ] || ! echo "$COMMAND" | grep -qiE "(git commit|gh (issue|pr|api))"; then
    exit 0
fi

log_message "Git workflow command detected: $COMMAND"

# Determine workflow type and extract details
WORKFLOW_TYPE="unknown"
CONTENT=""
IMPORTANCE=0.5
EXTRA_TAGS=""

# Git commit
if echo "$COMMAND" | grep -qi "git commit"; then
    WORKFLOW_TYPE="commit"

    # Get commit message and branch from git log
    if [ -n "$CWD" ] && [ -d "$CWD" ]; then
        COMMIT_MSG=$(cd "$CWD" && git log -1 --pretty=%s 2>/dev/null)
        BRANCH=$(cd "$CWD" && git branch --show-current 2>/dev/null)
    else
        COMMIT_MSG=$(git log -1 --pretty=%s 2>/dev/null)
        BRANCH=$(git branch --show-current 2>/dev/null)
    fi

    # Skip merge commits entirely - zero information content
    MERGE_PARENTS=""
    if [ -n "$CWD" ] && [ -d "$CWD" ]; then
        MERGE_PARENTS=$(cd "$CWD" && git rev-list --parents -n 1 HEAD 2>/dev/null)
    else
        MERGE_PARENTS=$(git rev-list --parents -n 1 HEAD 2>/dev/null)
    fi
    PARENT_COUNT=$(echo "$MERGE_PARENTS" | awk '{print NF - 1}')
    if [ -n "$PARENT_COUNT" ] && [ "$PARENT_COUNT" -gt 1 ] 2>/dev/null; then
        log_message "Skipping merge commit: $COMMIT_MSG"
        SCRIPT_SUCCESS=true
        exit 0
    fi

    # Get files changed count from output (portable - no grep -P)
    FILES_CHANGED=$(echo "$OUTPUT" | perl -nle 'print $1 if /(\d+) files? changed/' | head -1)

    CONTENT="Committed to ${PROJECT_NAME}: ${COMMIT_MSG:-unknown}${BRANCH:+ on $BRANCH}${FILES_CHANGED:+ ($FILES_CHANGED files)}"
    EXTRA_TAGS="commit"

    # Importance based on commit type (conventional commits)
    case "$COMMIT_MSG" in
        feat:*|feat\(*) IMPORTANCE=0.6 ;;
        fix:*|fix\(*)   IMPORTANCE=0.6 ;;
        chore:*|docs:*|style:*|ci:*) IMPORTANCE=0.4 ;;
        refactor:*|perf:*|test:*) IMPORTANCE=0.5 ;;
        *)               IMPORTANCE=0.5 ;;
    esac

# GitHub Issue creation
elif echo "$COMMAND" | grep -qi "gh issue create"; then
    WORKFLOW_TYPE="issue-create"

    ISSUE_TITLE=$(echo "$COMMAND" | perl -nle 'print $1 if /--title ["\x27]([^"\x27]+)/' | head -1)
    ISSUE_URL=$(echo "$OUTPUT" | perl -nle 'print $1 if m{(https://github\.com/\S+)}' | head -1)
    ISSUE_NUM=$(echo "$ISSUE_URL" | perl -nle 'print $1 if /(\d+)$/')

    CONTENT="Created issue #${ISSUE_NUM:-?} in ${PROJECT_NAME}: ${ISSUE_TITLE:-see URL}${ISSUE_URL:+ - $ISSUE_URL}"
    EXTRA_TAGS="issue,created"
    IMPORTANCE=0.6

# GitHub Issue close
elif echo "$COMMAND" | grep -qi "gh issue close"; then
    WORKFLOW_TYPE="issue-close"

    ISSUE_NUM=$(echo "$COMMAND" | perl -nle 'print $1 if /close (\d+)/')

    CONTENT="Closed issue #${ISSUE_NUM:-?} in ${PROJECT_NAME}"
    EXTRA_TAGS="issue,closed"
    IMPORTANCE=0.5

# GitHub PR merge - the primary "work shipped" signal
elif echo "$COMMAND" | grep -qi "gh pr merge"; then
    WORKFLOW_TYPE="pr-merge"

    PR_NUM=$(echo "$COMMAND" | perl -nle 'print $1 if /merge (\d+)/')
    if [ -z "$PR_NUM" ]; then
        PR_NUM=$(echo "$OUTPUT" | perl -nle 'print $1 if /#(\d+)/' | head -1)
    fi

    # Enrich: fetch PR title and linked issues for a richer memory
    PR_TITLE=""
    PR_BODY_ISSUES=""
    if [ -n "$PR_NUM" ]; then
        PR_REPO=""
        if [ -n "$CWD" ] && [ -d "$CWD" ]; then
            PR_REPO=$(cd "$CWD" && git remote get-url origin 2>/dev/null | perl -nle 'print $1 if m{[:/]([^/]+/[^/.]+?)(?:\.git)?$}')
        else
            PR_REPO=$(git remote get-url origin 2>/dev/null | perl -nle 'print $1 if m{[:/]([^/]+/[^/.]+?)(?:\.git)?$}')
        fi
        if [ -n "$PR_REPO" ]; then
            PR_TITLE=$(gh pr view "$PR_NUM" --repo "$PR_REPO" --json title -q '.title' 2>/dev/null)
            # Extract linked issue numbers from PR body
            PR_BODY_ISSUES=$(gh pr view "$PR_NUM" --repo "$PR_REPO" --json body -q '.body' 2>/dev/null \
                | perl -nle 'print $1 while /(?:closes?|fixes?|resolves?)\s+#(\d+)/gi' \
                | sort -u | paste -sd, -)
        fi
    fi

    CONTENT="Merged PR #${PR_NUM:-?} in ${PROJECT_NAME}"
    [ -n "$PR_TITLE" ] && CONTENT="$CONTENT: $PR_TITLE"
    [ -n "$PR_BODY_ISSUES" ] && CONTENT="$CONTENT (closes #$PR_BODY_ISSUES)"
    EXTRA_TAGS="pr,merged"
    IMPORTANCE=0.8

# GitHub PR view (review status only)
elif echo "$COMMAND" | grep -qi "gh pr view"; then
    # Only capture if review contains approval or change requests
    if echo "$OUTPUT" | grep -qi "approved\|requested changes"; then
        WORKFLOW_TYPE="pr-review"
        PR_NUM=$(echo "$COMMAND" | perl -nle 'print $1 if /view (\d+)/')

        REVIEW_STATUS=""
        if echo "$OUTPUT" | grep -qi "approved"; then
            REVIEW_STATUS="approved"
        elif echo "$OUTPUT" | grep -qi "requested changes"; then
            REVIEW_STATUS="changes requested"
        fi

        CONTENT="PR #${PR_NUM:-?} review in ${PROJECT_NAME}: ${REVIEW_STATUS}"
        EXTRA_TAGS="pr,review"
        IMPORTANCE=0.5
    else
        exit 0
    fi

# GitHub API calls for PR reviews
elif echo "$COMMAND" | grep -qi "gh api.*pulls.*comments\|gh api.*pulls.*reviews"; then
    WORKFLOW_TYPE="pr-review-api"
    PR_NUM=$(echo "$COMMAND" | perl -nle 'print $1 if m{pulls/(\d+)}')

    if echo "$OUTPUT" | grep -qi "body\|comment\|state"; then
        CONTENT="Fetched PR #${PR_NUM:-?} review data in ${PROJECT_NAME}"
        EXTRA_TAGS="pr,review,api"
        IMPORTANCE=0.5
    else
        exit 0
    fi

else
    exit 0
fi

# Skip if we couldn't generate meaningful content
if [ -z "$CONTENT" ] || [ "$CONTENT" = "unknown" ]; then
    log_message "Skipping - no meaningful content extracted"
    exit 0
fi

# Truncate content to prevent errors (max 1500 chars)
MAX_CONTENT_LEN=1500
if [ ${#CONTENT} -gt $MAX_CONTENT_LEN ]; then
    log_message "Truncating content from ${#CONTENT} to $MAX_CONTENT_LEN chars"
    CONTENT="${CONTENT:0:$MAX_CONTENT_LEN}..."
fi

# Truncate command in metadata (heredocs can be huge)
MAX_CMD_LEN=500
if [ ${#COMMAND} -gt $MAX_CMD_LEN ]; then
    COMMAND="${COMMAND:0:$MAX_CMD_LEN}..."
fi

# Queue memory for processing
TIMESTAMP=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

MEMORY_RECORD=$(jq -cn \
    --arg content "$CONTENT" \
    --arg type "$WORKFLOW_TYPE" \
    --arg project "$PROJECT_NAME" \
    --arg command "$COMMAND" \
    --arg timestamp "$TIMESTAMP" \
    --arg extra_tags "$EXTRA_TAGS" \
    --argjson importance "$IMPORTANCE" \
    '{
      content: $content,
      tags: (["git-workflow"] + ($extra_tags | split(",")) + ["repo:" + $project]),
      importance: $importance,
      type: "Context",
      metadata: {
        workflow_type: $type,
        project: $project,
        command: $command
      },
      timestamp: $timestamp
    }')

# Write to queue with portable file locking
AUTOMEM_QUEUE="$MEMORY_QUEUE" \
AUTOMEM_RECORD="$MEMORY_RECORD" \
python3 - <<'PY'
import os

try:
    import fcntl
except ImportError:
    fcntl = None

try:
    import msvcrt
except ImportError:
    msvcrt = None

def lock_file(handle):
    if fcntl is not None:
        fcntl.flock(handle, fcntl.LOCK_EX)
        return
    if msvcrt is not None:
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)

def unlock_file(handle):
    if fcntl is not None:
        fcntl.flock(handle, fcntl.LOCK_UN)
        return
    if msvcrt is not None:
        try:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        except OSError:
            pass

queue_path = os.environ.get("AUTOMEM_QUEUE", "")
record = os.environ.get("AUTOMEM_RECORD", "")
if queue_path and record:
    os.makedirs(os.path.dirname(queue_path), exist_ok=True)
    with open(queue_path, "a", encoding="utf-8") as handle:
        lock_file(handle)
        try:
            handle.write(record + "\n")
        finally:
            unlock_file(handle)
PY

log_message "Queued $WORKFLOW_TYPE memory (importance=$IMPORTANCE): $CONTENT"

SCRIPT_SUCCESS=true
exit 0
