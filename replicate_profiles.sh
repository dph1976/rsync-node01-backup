#!/usr/bin/env bash
# replicate_profiles.sh - chạy bằng root trên node01: đẩy Chrome profile + env + state sang node-backup.
# Dùng:  replicate_profiles.sh              -> sync tất cả (cron)
#        replicate_profiles.sh <container>  -> chỉ thử 1 container (không sync env/state, không ghi dấu OK)
# Cài bằng install_on_node01.sh (bản root-sở-hữu ở /usr/local/sbin); KHÔNG cho cron chạy thẳng file trong thư mục git.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEST=node-admin@100.90.40.40
export DAY=$(date +%F)
export SSH="ssh -i /root/.ssh/id_ed25519_replica -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15"
ONLY=${1:-}
OKFILE=/var/lib/replicate_profiles.ok
LOG=/data/logs/vps/replicate_profiles.log
# Chạy tay (có terminal): in ra màn hình và ghi log. Chạy cron: chỉ ghi log.
if [ -t 1 ]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
echo "== $(date -Is) start ${ONLY:+(chỉ thử: $ONLY)}"

# Report every invocation, including early exits, without requiring a remote shell.
STARTED=$(date -Is)
RESULT=ERROR
report_result() {
  local rc=$? report
  trap - EXIT
  report=$(mktemp "/tmp/sync-result-$(date +%Y%m%dT%H%M%S)-XXXXXX.log") || {
    echo "FAIL create sync result file"; exit "$rc";
  }
  printf '%s started=%s mode=%s result=%s rc=%s ok=%s skip=%s fail=%s envfail=%s\n' \
    "$(date -Is)" "$STARTED" "${ONLY:-full}" "$RESULT" "$rc" \
    "${nok:--}" "${nskip:--}" "${nfail:--}" "${envfail:--}" > "$report"
  if ! rsync -t --timeout=30 -e "$SSH" "$report" "$DEST:state/$(basename "$report")"; then
    echo "FAIL push sync result (record remains in local log)"
    cat "$report"
  fi
  rm -f -- "$report"
  exit "$rc"
}
trap report_result EXIT

exec 9>/var/lock/replicate_profiles.lock
flock -n 9 || { RESULT=SKIP_LOCKED; echo "đang có lần chạy khác"; exit 0; }

if [ -z "$ONLY" ] && [ "$(cat "$OKFILE" 2>/dev/null)" = "$DAY" ]; then
  RESULT=SKIP_ALREADY_DONE; echo "hôm nay đã xong"; exit 0
fi

if pgrep -f 'Worker_for_SmartOne.py|Worker_Controller.py|run_controller.sh|run_oot_summary.sh|backup_vps_volumes.sh|Controler_for_SSI.py|Worker_for_SSI.py|Get_token_for_SSI_accounts.py' >/dev/null; then
  RESULT=SKIP_BUSY; echo "còn tiến trình BOT3CC đang chạy -> thử lại sau"; exit 2
fi

timeout 8 bash -c '</dev/tcp/100.90.40.40/22' || { RESULT=UNREACHABLE; echo "node-backup không tới được (cổng 22)"; exit 3; }

names=$(docker ps --format '{{.Names}}' | grep '^VPS\.' | sort)
if [ -n "$ONLY" ]; then names=$(printf '%s\n' "$names" | grep -Fx "$ONLY"); fi
[ -n "$names" ] || { RESULT=NO_CONTAINERS; echo "không có container VPS.* phù hợp"; exit 4; }

export RES=$(mktemp /tmp/replicate_res.XXXXXX)

sync_one() {
  c=$1
  out=$(docker top "$c" -eo pid,comm 2>&1) || { echo "$c SKIP" >> "$RES"; echo "SKIP $c (docker top lỗi)"; return 0; }
  if printf '%s\n' "$out" | awk 'NR>1 && ($2=="chrome" || $2=="chromedriver"){f=1} END{exit !f}'; then
    echo "$c SKIP" >> "$RES"; echo "SKIP $c (trình duyệt đang chạy)"; return 0
  fi
  src=$(docker volume inspect "$c" --format '{{.Mountpoint}}') || { echo "$c FAIL" >> "$RES"; echo "FAIL $c (không đọc được volume)"; return 0; }
  if [ ! -d "$src/Default" ]; then
    echo "$c SKIP" >> "$RES"; echo "SKIP $c (không thấy Default/)"; return 0
  fi
  rsync -rlpt --delete --partial --timeout=300 --backup --backup-dir="/history/$DAY/$c" \
    --exclude='Singleton*' --exclude='lockfile' --exclude='Crashpad/' \
    --exclude='Cache/' --exclude='Code Cache/' --exclude='GPUCache/' \
    --exclude='GrShaderCache/' --exclude='ShaderCache/' --exclude='CacheStorage/' \
    -e "$SSH" "$src/" "$DEST:volumes/$c/"
  rc=$?
  case $rc in
    0|24) echo "$c OK" >> "$RES"; echo "OK   $c" ;;
    *)    echo "$c FAIL" >> "$RES"; echo "FAIL $c (rsync rc=$rc)" ;;
  esac
  return 0
}
export -f sync_one

printf '%s\n' "$names" | xargs -P3 -I{} bash -c 'sync_one "$1"' _ {}
nok=$(grep -c ' OK$' "$RES"); nskip=$(grep -c ' SKIP$' "$RES"); nfail=$(grep -c ' FAIL$' "$RES")
rm -f "$RES"
echo "profiles: OK=$nok SKIP=$nskip FAIL=$nfail"

if [ -n "$ONLY" ]; then
  echo "== $(date -Is) end (chế độ thử, không sync env/state)"
  if [ "$nfail" -eq 0 ] && [ "$nskip" -eq 0 ]; then RESULT=TEST_OK; exit 0; fi
  RESULT=TEST_INCOMPLETE; exit 1
fi

envfail=0
push() { # push <nguồn/> <đích> [tùy chọn rsync...]
  src=$1; dst=$2; shift 2
  rsync -rlpt --delete --timeout=300 "$@" -e "$SSH" "$src" "$DEST:$dst"
  rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 24 ]; then echo "FAIL push $dst (rc=$rc)"; envfail=$((envfail+1)); fi
}

S=/tmp/node01-state; rm -rf "$S"; mkdir -p "$S"
runuser -u node-admin -- git -C /home/node-admin/VPS-Automation describe --tags --always > "$S/vps-describe.txt" 2>&1
runuser -u node-admin -- git -C /home/node-admin/VPS-Automation status --short           > "$S/vps-status.txt" 2>&1
runuser -u node-admin -- git -C /home/node-admin/ssi-runtime describe --tags --always    > "$S/ssi-describe.txt" 2>&1
crontab -u node-admin -l > "$S/crontab.txt" 2>&1
if ! crontab -u root -l > "$S/crontab.root.txt" 2>&1; then
  echo "FAIL read root crontab"; envfail=$((envfail+1))
fi
/home/node-admin/venv-automation/bin/python -m pip freeze > "$S/pip-freeze.txt" 2>&1
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "$S/docker-ps.txt" 2>&1
docker image ls --digests > "$S/docker-images.txt" 2>&1

push /home/node-admin/VPS-Automation/ env/VPS-Automation/ --exclude='logs/' --exclude='__pycache__/'
push /home/node-admin/ssi-runtime/    env/ssi-runtime/    --exclude='logs/' --exclude='__pycache__/'
# Secrets are host-specific and must never be mirrored from node01.
# Preserve receiver-side result records during the state mirror (--delete).
push "$S/" state/ --exclude='/sync-result-*.log'

if [ "$nfail" -eq 0 ] && [ "$nskip" -eq 0 ] && [ "$envfail" -eq 0 ]; then
  date -Is > /tmp/_LAST_OK
  if rsync -t -e "$SSH" /tmp/_LAST_OK "$DEST:_LAST_OK"; then
    date +%F > "$OKFILE"; echo "ĐÃ XONG hôm nay"
  else
    echo "FAIL push _LAST_OK"; envfail=$((envfail+1))
  fi
fi
echo "== $(date -Is) end ok=$nok skip=$nskip fail=$nfail envfail=$envfail"
if [ "$nfail" -eq 0 ] && [ "$nskip" -eq 0 ] && [ "$envfail" -eq 0 ]; then RESULT=OK; exit 0; fi
RESULT=INCOMPLETE; exit 1
