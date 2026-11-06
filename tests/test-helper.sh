#!/usr/bin/env bash
#
# Tests for system/faceunlock-helper. Howdy and the camera are replaced by stubs
# and every path points into a temp dir, so this never touches the real system.
# Needs root because the helper refuses to run without it:
#
#   sudo tests/test-helper.sh

set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: the helper refuses to run as a normal user." >&2; exit 2; }

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
helper="$root/system/faceunlock-helper"
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT

mkdir -p "$sandbox/pam" "$sandbox/v4l"
touch "$sandbox/v4l/usb-Test_Camera_123-video-index0"
cat >"$sandbox/config.ini" <<'EOF'
[core]
disabled = false
[video]
timeout = 4
device_path = /dev/null
dark_threshold = 75
[face]
sface_threshold = 0.6942
[debug]
end_report = false
EOF

# The stubs log their arguments, so tests can assert what would have run.
cat >"$sandbox/howdy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$sandbox/howdy.log"
case "\$*" in
*"list --plain"*) printf '0,2026-01-02 03:04:05,default\n1,2026-01-02 03:05:00,with, comma\n' ;;
version) echo "Howdy Test 1.0" ;;
esac
EOF
cat >"$sandbox/compare" <<EOF
#!/usr/bin/env bash
if [[ -f "$sandbox/fail" ]]; then echo "All frames were too dark; check dark_threshold"; exit 11; fi
printf 'Total time: 1ms\nWinning score: 0.738734\nWinning model: 1 ("angle")\n'
EOF
chmod +x "$sandbox/howdy" "$sandbox/compare"

run() {
    env -i PKEXEC_UID="${TEST_UID-0}" \
        FACEUNLOCK_CONFIG="$sandbox/config.ini" FACEUNLOCK_PAM_DIR="$sandbox/pam" \
        FACEUNLOCK_COMPARE="$sandbox/compare" FACEUNLOCK_HOWDY="$sandbox/howdy" \
        FACEUNLOCK_V4L_BY_ID="$sandbox/v4l" bash "$helper" "$@"
}

passed=0 failed=0
check() {
    local name=$1 expected=$2 actual=$3
    if [[ $actual == "$expected" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
    fi
}
field() { jq -r "$1" <<<"$2"; }
rejected() { check "rejects: $1" false "$(field .ok "$(run "${@:2}")")"; }
accepted() { check "accepts: $1" true "$(field .ok "$(run "${@:2}")")"; }
ran() { grep -cF -- "$1" "$sandbox/howdy.log" 2>/dev/null || true; }

# --- identity
check "non-numeric caller is refused" false "$(field .ok "$(TEST_UID=abc run read status)")"
check "unset caller is refused" false "$(field .ok "$(env -i FACEUNLOCK_CONFIG="$sandbox/config.ini" bash "$helper" read status)")"
check "unknown caller is refused" false "$(field .ok "$(TEST_UID=4000000 run read status)")"

# --- routing: changes must never be reachable through the no-password scope
rejected "add through read scope" read add hello
rejected "enable through read scope" read enable
rejected "set through read scope" read set timeout 3
rejected "clear through read scope" read clear
rejected "lock change through read scope" read lock-enable
rejected "status through manage scope" manage status
rejected "unknown command" manage bogus
rejected "no arguments"

# --- status
status=$(run read status)
check "status ok" true "$(field .ok "$status")"
check "status enabled" true "$(field .data.enabled "$status")"
check "status timeout" 4 "$(field .data.timeout "$status")"
check "status threshold" 0.6942 "$(field .data.threshold "$status")"
check "status model count" 2 "$(field '.data.models|length' "$status")"
check "status model id" 0 "$(field '.data.models[0].id' "$status")"
check "status label keeps commas" "with, comma" "$(field '.data.models[1].label' "$status")"
check "status finds camera" 1 "$(field '.data.cameras|length' "$status")"
check "status camera name" "Test_Camera_123" "$(field '.data.cameras[0].name' "$status")"
check "status lock off" false "$(field .data.pam.lock "$status")"
check "status lock absent" absent "$(field .data.pam.lockState "$status")"

# --- labels: nothing that could become an option or escape the argument
accepted "plain label" manage add "My Face_1-a"
for bad in "" "-U root" "--plain" "a;b" 'a$(id)' "a/b" 'a"b' "$(printf 'a\nb')" \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; do
    rejected "label [$bad]" manage add "$bad"
done
check "adds for the caller only" 1 "$(ran "-U root add --plain -y My Face_1-a")"

# --- remove
accepted "numeric id" manage remove 3
for bad in "" abc "-1" "1;2" "12345" "--all"; do rejected "id [$bad]" manage remove "$bad"; done

# --- settings
accepted "timeout" manage set timeout 5
for bad in 0 16 abc "-1" "5;id" "1.5"; do rejected "timeout [$bad]" manage set timeout "$bad"; done
accepted "threshold" manage set sface_threshold 0.7
for bad in 0.1 0.95 abc "0.7;id" "--x"; do rejected "threshold [$bad]" manage set sface_threshold "$bad"; done
accepted "dark limit" manage set dark_threshold 80.5
for bad in 100 "-1" abc; do rejected "dark limit [$bad]" manage set dark_threshold "$bad"; done
accepted "known camera" manage set device_path "$sandbox/v4l/usb-Test_Camera_123-video-index0"
for bad in /etc/shadow /dev/video0 "$sandbox/v4l/missing" "$sandbox/v4l/../config.ini"; do
    rejected "camera [$bad]" manage set device_path "$bad"
done
for key in abort_if_ssh disabled no_confirmation "timeout;id" ""; do
    rejected "setting [$key]" manage set "$key" 1
done

# --- enable and disable
: >"$sandbox/howdy.log"
accepted "enable" manage enable
check "enable clears the disabled flag" 1 "$(ran "disable 0")"
accepted "disable" manage disable
check "disable sets the disabled flag" 1 "$(ran "disable 1")"

# --- lock screen PAM file
accepted "lock enable" manage lock-enable
pam="$sandbox/pam/dankshell"
check "lock file has marker" 1 "$(grep -c 'Managed by dms-face-unlock' "$pam")"
check "face tried before password" 1 "$(awk '/pam_howdy/{h=NR} /pam_unix.so *try_first_pass/{u=NR} END{print (h && u && h<u)}' "$pam")"
check "password is still a fallback" 1 "$(grep -c 'sufficient.*pam_unix.so' "$pam")"
check "lock file is world-readable" 644 "$(stat -c %a "$pam")"
check "lock reported on" true "$(field .data.pam.lock "$(run read status)")"
check "lock reported managed" managed "$(field .data.pam.lockState "$(run read status)")"
accepted "lock enable again" manage lock-enable
accepted "lock disable" manage lock-disable
check "lock file removed" no "$([[ -e $pam ]] && echo yes || echo no)"
accepted "lock disable when absent" manage lock-disable

printf '#%%PAM-1.0\nauth required pam_custom.so\n' >"$pam"
before=$(cat "$pam")
rejected "overwriting a custom lock file" manage lock-enable
rejected "removing a custom lock file" manage lock-disable
check "custom lock file untouched" "$before" "$(cat "$pam")"
check "custom lock reported" custom "$(field .data.pam.lockState "$(run read status)")"
rm -f "$pam"

# --- other services are only reported, and comments don't count
printf 'auth sufficient pam_howdy.so\n' >"$sandbox/pam/sudo"
printf '# auth sufficient pam_howdy.so\n' >"$sandbox/pam/greetd"
status=$(run read status)
check "sudo detected" true "$(field .data.pam.sudo "$status")"
check "commented line ignored" false "$(field .data.pam.greeter "$status")"

# --- match test
result=$(run read test)
check "test matched" true "$(field .data.matched "$result")"
check "test score" 0.738734 "$(field .data.score "$result")"
check "test model" angle "$(field .data.model "$result")"
check "test threshold" 0.6942 "$(field .data.threshold "$result")"
touch "$sandbox/fail"
result=$(run read test)
check "test not matched" false "$(field .data.matched "$result")"
check "test too dark" true "$(field .data.tooDark "$result")"
check "no temp configs left" 0 "$(find "$sandbox" -name '.faceunlock.*' | wc -l)"
check "real config not edited" false "$(awk '/end_report/{print $3}' "$sandbox/config.ini")"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
