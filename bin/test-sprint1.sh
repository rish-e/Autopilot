#!/bin/bash
# test-sprint1.sh — Test suite for Sprint 1 components
#
# Tests: totp.sh, verify-email.sh, notify.sh, memory.py
# Run: ./bin/test-sprint1.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}SKIP${NC}: $1"; ((SKIP++)); }

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Testing totp.sh${NC}"
# ═════════════════════════════════════════════════════════════════════════════

TOTP="$SCRIPT_DIR/totp.sh"
KEYCHAIN="$SCRIPT_DIR/keychain.sh"

# Test: help text
if "$TOTP" --help &>/dev/null; then
    pass "totp.sh --help"
else
    fail "totp.sh --help"
fi

# Test: unknown command
if "$TOTP" badcmd 2>/dev/null; then
    fail "totp.sh rejects unknown commands"
else
    pass "totp.sh rejects unknown commands"
fi

# Test: generate without seed should fail
if "$TOTP" generate nonexistent-test-service 2>/dev/null; then
    fail "totp.sh generate fails without seed"
else
    pass "totp.sh generate fails without seed"
fi

# Test: store and generate with known RFC 6238 test vector
TEST_SERVICE="autopilot-test-totp"
TEST_SEED="GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

# Store the test seed
echo "$TEST_SEED" | "$KEYCHAIN" set "$TEST_SERVICE" totp-seed 2>/dev/null

# Check it exists
if "$TOTP" has "$TEST_SERVICE" 2>/dev/null; then
    pass "totp.sh has (seed exists after store)"
else
    fail "totp.sh has (seed exists after store)"
fi

# Generate a code
if command -v python3 &>/dev/null && python3 -c "import pyotp" 2>/dev/null; then
    CODE=$("$TOTP" generate "$TEST_SERVICE" 2>/dev/null)
    if [[ ${#CODE} -eq 6 && "$CODE" =~ ^[0-9]+$ ]]; then
        pass "totp.sh generate (6-digit code: $CODE)"
    else
        fail "totp.sh generate (expected 6-digit code, got: '$CODE')"
    fi

    # Test remaining
    REM=$("$TOTP" remaining "$TEST_SERVICE" 2>/dev/null)
    if [[ "$REM" =~ ^[0-9]+$ && "$REM" -ge 0 && "$REM" -le 30 ]]; then
        pass "totp.sh remaining (${REM}s)"
    else
        fail "totp.sh remaining (got: '$REM')"
    fi
else
    skip "totp.sh generate (pyotp not installed)"
    skip "totp.sh remaining (pyotp not installed)"
fi

# Cleanup test seed
"$KEYCHAIN" delete "$TEST_SERVICE" totp-seed 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Testing verify-email.sh${NC}"
# ═════════════════════════════════════════════════════════════════════════════

VERIFY="$SCRIPT_DIR/verify-email.sh"

# Test: help text
if "$VERIFY" --help &>/dev/null; then
    pass "verify-email.sh --help"
else
    fail "verify-email.sh --help"
fi

# Test: query generation
QUERY=$("$VERIFY" query --from "noreply@vercel.com" --subject "verify" --minutes 3 2>/dev/null)
if [[ "$QUERY" == *"from:noreply@vercel.com"* && "$QUERY" == *"subject:"* && "$QUERY" == *"newer_than:3m"* ]]; then
    pass "verify-email.sh query (correct Gmail syntax)"
else
    fail "verify-email.sh query (got: '$QUERY')"
fi

# Test: query with only --from
QUERY=$("$VERIFY" query --from "test@example.com" 2>/dev/null)
if [[ "$QUERY" == *"from:test@example.com"* ]]; then
    pass "verify-email.sh query --from only"
else
    fail "verify-email.sh query --from only"
fi

# Test: query requires at least one filter
if "$VERIFY" query 2>/dev/null; then
    fail "verify-email.sh query rejects empty query"
else
    pass "verify-email.sh query rejects empty query"
fi

# Test: parse code extraction
CODE=$(echo "Your verification code is 847293. Enter it to continue." | "$VERIFY" parse --type code 2>/dev/null)
if [[ "$CODE" == "847293" ]]; then
    pass "verify-email.sh parse --type code"
else
    fail "verify-email.sh parse --type code (got: '$CODE')"
fi

# Test: parse code from body with multiple numbers
CODE=$(echo "Order #12345. Your code: 492038. Expires in 10 minutes." | "$VERIFY" parse --type code 2>/dev/null)
if [[ "$CODE" == "12345" || "$CODE" == "492038" ]]; then
    pass "verify-email.sh parse --type code (multiple numbers)"
else
    fail "verify-email.sh parse --type code multiple (got: '$CODE')"
fi

# Test: parse link extraction
LINK=$(echo 'Click here to verify: https://example.com/verify?token=abc123 or copy the link.' | "$VERIFY" parse --type link 2>/dev/null)
if [[ "$LINK" == *"example.com/verify"* ]]; then
    pass "verify-email.sh parse --type link"
else
    fail "verify-email.sh parse --type link (got: '$LINK')"
fi

# Test: parse link with custom pattern
LINK=$(echo 'Confirm at https://supabase.com/dashboard/confirm?code=xyz' | "$VERIFY" parse --type link --url-pattern "supabase.com" 2>/dev/null)
if [[ "$LINK" == *"supabase.com"* ]]; then
    pass "verify-email.sh parse --type link (custom pattern)"
else
    fail "verify-email.sh parse --type link custom (got: '$LINK')"
fi

# Test: parse fails on empty body
if echo "" | "$VERIFY" parse --type code 2>/dev/null; then
    fail "verify-email.sh parse rejects empty body"
else
    pass "verify-email.sh parse rejects empty body"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Testing notify.sh${NC}"
# ═════════════════════════════════════════════════════════════════════════════

NOTIFY="$SCRIPT_DIR/notify.sh"

# Test: help text
if "$NOTIFY" --help &>/dev/null; then
    pass "notify.sh --help"
else
    fail "notify.sh --help"
fi

# Test: channels listing
if "$NOTIFY" channels &>/dev/null; then
    pass "notify.sh channels"
else
    fail "notify.sh channels"
fi

# Test: send requires --message
if "$NOTIFY" send 2>/dev/null; then
    fail "notify.sh send rejects missing --message"
else
    pass "notify.sh send rejects missing --message"
fi

# Test: unknown channel
if "$NOTIFY" send --message "test" --channel "nonexistent" 2>/dev/null; then
    fail "notify.sh send rejects unknown channel"
else
    pass "notify.sh send rejects unknown channel"
fi

# Test: unknown command
if "$NOTIFY" badcommand 2>/dev/null; then
    fail "notify.sh rejects unknown commands"
else
    pass "notify.sh rejects unknown commands"
fi

# Note: actual send tests require configured channels — skipping
skip "notify.sh send (requires configured ntfy topic)"
skip "notify.sh send telegram (requires configured bot)"

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Testing memory.py${NC}"
# ═════════════════════════════════════════════════════════════════════════════

MEMORY="python3 $AUTOPILOT_DIR/lib/memory.py"
TEST_DB="/tmp/autopilot-test-memory-$$.db"

# Test: schema creation
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
tables = [r[0] for r in mem.db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall()]
expected = {'traces', 'procedures', 'errors', 'services', 'playbooks', 'costs', 'health', 'kv'}
missing = expected - set(tables)
if missing:
    print(f'Missing tables: {missing}', file=sys.stderr)
    sys.exit(1)
mem.close()
" 2>/dev/null && pass "memory.py schema creation (8 tables)" || fail "memory.py schema creation"

# Test: trace logging and retrieval
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.log_trace('run1', 1, 'deploy', tool='Bash', service='vercel', status='ok')
mem.log_trace('run1', 2, 'migrate', tool='Bash', service='supabase', status='error', error_msg='timeout')
traces = mem.get_run('run1')
assert len(traces) == 2, f'Expected 2 traces, got {len(traces)}'
assert traces[0]['status'] == 'ok'
assert traces[1]['status'] == 'error'
assert traces[1]['error_msg'] == 'timeout'
mem.close()
" 2>/dev/null && pass "memory.py trace logging + retrieval" || fail "memory.py trace logging"

# Test: procedure save, find, run recording
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.save_procedure('deploy_vercel', 'deploy next.js to vercel', [{'cmd': 'vercel deploy'}], services=['vercel'])
mem.record_procedure_run('deploy_vercel', True, 5000, 0.05)
mem.record_procedure_run('deploy_vercel', True, 4500, 0.04)
mem.record_procedure_run('deploy_vercel', False, 8000, 0.06)
results = mem.find_procedure(task_desc='deploy to vercel')
assert len(results) > 0, 'No procedure found'
proc = results[0]
assert proc['name'] == 'deploy_vercel'
assert proc['success_count'] == 2
assert proc['fail_count'] == 1
mem.close()
" 2>/dev/null && pass "memory.py procedure save + find + run recording" || fail "memory.py procedures"

# Test: error logging and known-error lookup
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.log_error('timeout', 'connection timed out', service='supabase',
              resolution='retry with --db-timeout 60')
match = mem.check_known_error('Error: connection timed out after 30s', service='supabase')
assert match is not None, 'No error match found'
assert 'retry' in match['resolution'], f'Bad resolution: {match[\"resolution\"]}'
# Log same error again — count should increment
mem.log_error('timeout', 'connection timed out', service='supabase')
row = mem.db.execute('SELECT count FROM errors WHERE service = ?', ('supabase',)).fetchone()
assert row['count'] == 2, f'Expected count 2, got {row[\"count\"]}'
mem.close()
" 2>/dev/null && pass "memory.py error logging + dedup + known-error lookup" || fail "memory.py errors"

# Test: service caching
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.cache_service('vercel', cli_tool='vercel', category='deployment',
                  has_mcp=0, has_playbook=1, has_registry=1)
svc = mem.get_service('vercel')
assert svc is not None, 'Service not found'
assert svc['cli_tool'] == 'vercel'
assert svc['category'] == 'deployment'
assert svc['has_playbook'] == 1
# Update should work
mem.cache_service('vercel', has_mcp=1, mcp_package='@vercel/mcp')
svc = mem.get_service('vercel')
assert svc['has_mcp'] == 1, 'MCP flag not updated'
assert svc['cli_tool'] == 'vercel', 'CLI tool was overwritten'
mem.close()
" 2>/dev/null && pass "memory.py service caching + update" || fail "memory.py services"

# Test: cost tracking
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.log_cost('run1', 'opus', tokens_in=1000, tokens_out=500, cost_usd=0.05)
mem.log_cost('run1', 'haiku', tokens_in=200, tokens_out=100, cost_usd=0.001)
mem.log_cost('run2', 'sonnet', tokens_in=500, tokens_out=300, cost_usd=0.02)
summary = mem.get_cost_summary(1)
assert summary['tasks'] == 2, f'Expected 2 tasks, got {summary[\"tasks\"]}'
assert summary['total_cost'] > 0.07, f'Total cost too low: {summary[\"total_cost\"]}'
by_model = mem.get_cost_by_model(1)
assert len(by_model) == 3, f'Expected 3 models, got {len(by_model)}'
mem.close()
" 2>/dev/null && pass "memory.py cost tracking + summary + by-model" || fail "memory.py costs"

# Test: playbook registration
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.register_playbook('vercel', 'signup', '/path/to/playbook.yaml')
pb = mem.get_playbook('vercel', 'signup')
assert pb is not None, 'Playbook not found'
assert pb['service'] == 'vercel'
assert pb['flow'] == 'signup'
mem.record_playbook_run('vercel', 'signup', True, 12000)
mem.record_playbook_run('vercel', 'signup', True, 10000)
pb = mem.get_playbook('vercel', 'signup')
assert pb['success_count'] == 2
mem.close()
" 2>/dev/null && pass "memory.py playbook registration + run tracking" || fail "memory.py playbooks"

# Test: health logging
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.log_health('vercel', 'api', 'ok', response_ms=120)
mem.log_health('supabase', 'db', 'ok', response_ms=45)
mem.log_health('vercel', 'api', 'error', message='502 Bad Gateway', response_ms=5000)
statuses = mem.get_health_status()
# Should have latest for each service+check_type
vercel_status = [s for s in statuses if s['service'] == 'vercel'][0]
assert vercel_status['status'] == 'error', 'Should show latest (error)'
mem.close()
" 2>/dev/null && pass "memory.py health logging + latest status" || fail "memory.py health"

# Test: KV store
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
mem.kv_set('last_run', 'run-001')
assert mem.kv_get('last_run') == 'run-001'
mem.kv_set('last_run', 'run-002')  # update
assert mem.kv_get('last_run') == 'run-002'
assert mem.kv_get('nonexistent') is None
mem.kv_delete('last_run')
assert mem.kv_get('last_run') is None
mem.close()
" 2>/dev/null && pass "memory.py KV store (set, get, update, delete)" || fail "memory.py KV"

# Test: stats
python3 -c "
import sys; sys.path.insert(0, '$AUTOPILOT_DIR/lib')
from memory import AutopilotMemory
mem = AutopilotMemory('$TEST_DB')
stats = mem.get_stats()
assert stats['traces'] > 0, 'Should have traces'
assert stats['procedures'] > 0, 'Should have procedures'
assert stats['errors'] > 0, 'Should have errors'
assert stats['services'] > 0, 'Should have services'
mem.close()
" 2>/dev/null && pass "memory.py stats aggregation" || fail "memory.py stats"

# Test: CLI commands
AUTOPILOT_MEMORY_DB="$TEST_DB" python3 "$AUTOPILOT_DIR/lib/memory.py" stats &>/dev/null \
    && pass "memory.py CLI: stats" || fail "memory.py CLI: stats"
AUTOPILOT_MEMORY_DB="$TEST_DB" python3 "$AUTOPILOT_DIR/lib/memory.py" runs &>/dev/null \
    && pass "memory.py CLI: runs" || fail "memory.py CLI: runs"
AUTOPILOT_MEMORY_DB="$TEST_DB" python3 "$AUTOPILOT_DIR/lib/memory.py" costs &>/dev/null \
    && pass "memory.py CLI: costs" || fail "memory.py CLI: costs"
AUTOPILOT_MEMORY_DB="$TEST_DB" python3 "$AUTOPILOT_DIR/lib/memory.py" errors &>/dev/null \
    && pass "memory.py CLI: errors" || fail "memory.py CLI: errors"
AUTOPILOT_MEMORY_DB="$TEST_DB" python3 "$AUTOPILOT_DIR/lib/memory.py" health &>/dev/null \
    && pass "memory.py CLI: health" || fail "memory.py CLI: health"
AUTOPILOT_MEMORY_DB="$TEST_DB" python3 "$AUTOPILOT_DIR/lib/memory.py" services &>/dev/null \
    && pass "memory.py CLI: services" || fail "memory.py CLI: services"
AUTOPILOT_MEMORY_DB="$TEST_DB" python3 "$AUTOPILOT_DIR/lib/memory.py" procedures &>/dev/null \
    && pass "memory.py CLI: procedures" || fail "memory.py CLI: procedures"

# Cleanup test DB
rm -f "$TEST_DB"

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Testing existing guardian (regression)${NC}"
# ═════════════════════════════════════════════════════════════════════════════

# Run a subset of existing guardian tests to ensure we haven't broken anything
GUARDIAN="$SCRIPT_DIR/guardian.sh"

test_guardian_block() {
    local desc="$1" cmd="$2"
    echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}" | "$GUARDIAN" >/dev/null 2>&1
    if [ $? -eq 2 ]; then pass "guardian blocks: $desc"
    else fail "guardian should block: $desc"; fi
}

test_guardian_allow() {
    local desc="$1" cmd="$2"
    echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}" | "$GUARDIAN" >/dev/null 2>&1
    if [ $? -eq 0 ]; then pass "guardian allows: $desc"
    else fail "guardian should allow: $desc"; fi
}

test_guardian_block "rm -rf /" "rm -rf /"
test_guardian_block "force push" "git push --force origin main"
test_guardian_block "terraform destroy" "terraform destroy"
test_guardian_allow "npm install" "npm install express"
test_guardian_allow "git status" "git status"
test_guardian_allow "vercel deploy preview" "vercel deploy --yes"

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + FAIL + SKIP))
echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}Sprint 1 Test Results${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}  TOTAL: $TOTAL"

if [ $FAIL -gt 0 ]; then
    echo -e "\n${RED}${BOLD}SOME TESTS FAILED${NC}"
    exit 1
else
    echo -e "\n${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    exit 0
fi
