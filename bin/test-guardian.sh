#!/bin/bash
# test-guardian.sh — Tests the guardian hook with dangerous and safe commands
# Run this directly: ~/MCPs/autopilot/bin/test-guardian.sh

GUARDIAN="$HOME/MCPs/autopilot/bin/guardian.sh"
PASS=0
FAIL=0

test_block() {
    local desc="$1" cmd="$2"
    local json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
    echo "$json" | "$GUARDIAN" >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        echo "  PASS (blocked): $desc"
        ((PASS++))
    else
        echo "  FAIL (should block): $desc — command: $cmd"
        ((FAIL++))
    fi
}

test_allow() {
    local desc="$1" cmd="$2"
    local json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
    echo "$json" | "$GUARDIAN" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "  PASS (allowed): $desc"
        ((PASS++))
    else
        echo "  FAIL (should allow): $desc — command: $cmd"
        ((FAIL++))
    fi
}

echo "=== Guardian Hook Tests ==="
echo ""

echo "--- Should BLOCK ---"
test_block "rm -rf /"                    'rm -rf /'
test_block "rm -rf ~"                    'rm -rf ~'
test_block "rm -rf \$HOME"              'rm -rf $HOME'
test_block "sudo rm -rf /var"            'sudo rm -rf /var'
test_block "git push --force"            'git push --force origin main'
test_block "git push -f"                 'git push -f origin main'
test_block "git reset --hard"            'git reset --hard HEAD~3'
test_block "git clean -f"               'git clean -fd'
test_block "npm publish"                 'npm publish'
test_block "cargo publish"               'cargo publish'
test_block "vercel --prod"               'vercel deploy --prod --yes'
test_block "echo keychain get"           'echo $(~/MCPs/autopilot/bin/keychain.sh get vercel api-token)'
test_block "DROP DATABASE"               'supabase db execute --sql DROP DATABASE mydb'
test_block "gh repo delete"              'gh repo delete myrepo --yes'
test_block "gh repo public"              'gh repo edit --visibility public'
test_block "terraform destroy"           'terraform destroy -auto-approve'
test_block "shutdown"                    'shutdown -h now'
test_block "mkfs"                        'mkfs.ext4 /dev/sda1'
test_block "fork bomb"                   ':(){ :|:&};:'
test_block "dd to disk"                  'dd if=/dev/zero of=/dev/sda bs=1M'
test_block "kill playwright"             'kill -9 $(pgrep playwright)'
test_block "pkill playwright"            'pkill -f playwright'
test_block "killall mcp"                 'killall mcp-server'
test_block "kill mcp process"            'kill $(pgrep mcp)'
echo ""

echo "--- Should ALLOW ---"
test_allow "npm install"                 'npm install'
test_allow "npm run build"               'npm run build'
test_allow "npm test"                    'npm test'
test_allow "git status"                  'git status'
test_allow "git push origin feat"        'git push origin feature-branch'
test_allow "git commit"                  'git commit -m "fix: stuff"'
test_allow "vercel deploy (preview)"     'vercel deploy --yes'
test_allow "vercel ls"                   'vercel ls --token abc'
test_allow "supabase projects list"      'supabase projects list'
test_allow "supabase db push"            'supabase db push'
test_allow "gh pr create"                'gh pr create --title "feat" --body "desc"'
test_allow "gh issue list"               'gh issue list'
test_allow "ls"                          'ls -la'
test_allow "mkdir"                       'mkdir -p /tmp/test'
test_allow "keychain set"               'echo "val" | ~/MCPs/autopilot/bin/keychain.sh set svc key'
test_allow "keychain has"               '~/MCPs/autopilot/bin/keychain.sh has vercel api-token'
test_allow "curl (read)"                 'curl -s https://api.example.com/status'
test_allow "brew install"                'brew install jq'
test_allow "python3"                     'python3 -c "print(1+1)"'
test_allow "which"                       'which node'
test_allow "Non-Bash tool"              '{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
    exit 1
fi
