#!/bin/bash
# verify-email.sh — Email verification helper for autonomous signup flows
#
# During service signup, the agent needs to:
#   1. Search for verification emails (via Gmail MCP)
#   2. Extract verification codes or links from the email body
#
# This script provides the search queries and extraction logic.
# The actual Gmail API calls are made by the agent via Gmail MCP tools.
#
# Usage:
#   verify-email.sh query --from <sender> --subject <keyword> [--minutes 5]
#   verify-email.sh parse --type link|code [--body <text> | stdin]
#   verify-email.sh parse --type link --url-pattern <regex> [--body <text> | stdin]
#
# Examples:
#   # Generate Gmail search query for Vercel verification
#   verify-email.sh query --from "noreply@vercel.com" --subject "verify"
#
#   # Parse a 6-digit code from email body
#   echo "$EMAIL_BODY" | verify-email.sh parse --type code
#
#   # Parse a verification link with specific pattern
#   echo "$EMAIL_BODY" | verify-email.sh parse --type link --url-pattern "verify|confirm|activate"

set -euo pipefail

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
verify-email.sh — Email verification helper for Autopilot signup flows

Commands:
  query    Generate a Gmail search query string for the agent to use
           with mcp__claude_ai_Gmail__gmail_search_messages

  parse    Extract verification code or link from email body text

Options for 'query':
  --from SENDER        Email sender address (e.g. noreply@vercel.com)
  --subject KEYWORD    Subject line keyword (e.g. "verify", "confirm")
  --minutes N          Search window in minutes (default: 5)
  --unread             Only match unread emails (default: true)

Options for 'parse':
  --type link|code     What to extract (required)
  --body TEXT          Email body text (or pipe via stdin)
  --url-pattern REGEX  URL pattern to match (default: verify|confirm|activate|validate|token)
  --code-length N      Expected code length (default: 4-8 digits)

Examples:
  verify-email.sh query --from "noreply@vercel.com" --subject "verify" --minutes 3
  echo "$BODY" | verify-email.sh parse --type code
  echo "$BODY" | verify-email.sh parse --type link --url-pattern "supabase.com/verify"

Agent workflow:
  1. query → get search string
  2. Agent calls gmail_search_messages with the query
  3. Agent calls gmail_read_message with the returned messageId
  4. parse → extract code or link from the email body
  5. Agent enters code in form or navigates to link
EOF
}

# ─── Query Command ───────────────────────────────────────────────────────────

cmd_query() {
    local from="" subject="" minutes=5 unread=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)    from="$2"; shift 2 ;;
            --subject) subject="$2"; shift 2 ;;
            --minutes) minutes="$2"; shift 2 ;;
            --unread)  unread=true; shift ;;
            --no-unread) unread=false; shift ;;
            *)
                echo "Error: Unknown option '$1' for query command" >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "$from" && -z "$subject" ]]; then
        echo "Error: At least --from or --subject is required" >&2
        echo "Run 'verify-email.sh --help' for usage" >&2
        exit 1
    fi

    # Build Gmail search query
    local query=""
    [[ -n "$from" ]] && query="from:${from}"
    [[ -n "$subject" ]] && query="${query:+$query }subject:(${subject})"
    query="${query} newer_than:${minutes}m"
    [[ "$unread" == "true" ]] && query="${query} is:unread"

    echo "$query"
}

# ─── Parse Command ───────────────────────────────────────────────────────────

cmd_parse() {
    local type="" body="" url_pattern="verify|confirm|activate|validate|token|auth" code_length=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)        type="$2"; shift 2 ;;
            --body)        body="$2"; shift 2 ;;
            --url-pattern) url_pattern="$2"; shift 2 ;;
            --code-length) code_length="$2"; shift 2 ;;
            *)
                echo "Error: Unknown option '$1' for parse command" >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "$type" ]]; then
        echo "Error: --type is required (link or code)" >&2
        exit 1
    fi

    # Read body from stdin if not provided as argument
    if [[ -z "$body" ]]; then
        if [[ -t 0 ]]; then
            echo "Error: --body required or pipe email body via stdin" >&2
            exit 1
        fi
        body=$(cat)
    fi

    if [[ -z "$body" ]]; then
        echo "Error: Empty email body" >&2
        exit 1
    fi

    case "$type" in
        code)
            # Extract verification code (4-8 digits by default)
            local pattern
            if [[ -n "$code_length" ]]; then
                pattern="\\b[0-9]{${code_length}}\\b"
            else
                pattern="\\b[0-9]{4,8}\\b"
            fi

            # Try to find code near verification-related context words
            local result
            result=$(echo "$body" | grep -oE "$pattern" | head -1)

            if [[ -n "$result" ]]; then
                echo "$result"
            else
                echo "Error: No verification code found in email body" >&2
                exit 1
            fi
            ;;

        link)
            # Extract verification URL matching the pattern
            local result
            result=$(echo "$body" | grep -oE "https?://[^[:space:]\"'<>]+($url_pattern)[^[:space:]\"'<>]*" | head -1)

            if [[ -n "$result" ]]; then
                # Clean trailing punctuation that might have been captured
                result=$(echo "$result" | sed 's/[.)>,;]*$//')
                echo "$result"
            else
                # Fallback: try to find any URL that looks like a verification link
                result=$(echo "$body" | grep -oE "https?://[^[:space:]\"'<>]+" | grep -iE "$url_pattern" | head -1)
                if [[ -n "$result" ]]; then
                    result=$(echo "$result" | sed 's/[.)>,;]*$//')
                    echo "$result"
                else
                    echo "Error: No verification link found in email body" >&2
                    echo "Searched for pattern: $url_pattern" >&2
                    exit 1
                fi
            fi
            ;;

        *)
            echo "Error: --type must be 'link' or 'code', got '$type'" >&2
            exit 1
            ;;
    esac
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

case "${1:-}" in
    query) shift; cmd_query "$@" ;;
    parse) shift; cmd_parse "$@" ;;
    -h|--help|help) usage ;;
    *)
        if [[ -n "${1:-}" ]]; then
            echo "Error: Unknown command '$1'" >&2
            echo "Run 'verify-email.sh --help' for usage" >&2
            exit 1
        fi
        usage
        exit 1
        ;;
esac
