#!/usr/bin/env bash
# Manual failover orchestration. Run as node-admin on node-backup.
set -Eeuo pipefail
umask 077
H=/home/node-admin
R=/data/replica
S="$H/.failover-swap"
PY="$H/venv-automation/bin/python"
IMAGE=selenium/standalone-chrome:157.0-20261101
[[ $(id -un) == node-admin && $(hostname -s) == node-backup ]] || { echo 'Run as node-admin on node-backup only.'; exit 1; }
mkdir -p "$S"
exec 9>"$S/lock"
flock -n 9 || { echo 'Another management session is running.'; exit 1; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
confirm(){ local answer; read -r -p "$* [YES]: " answer; [[ $answer == YES ]] || fail 'Cancelled.'; }
mode(){ if [[ -f $S/mode ]]; then cat "$S/mode"; else echo standby; fi; }
setmode(){ printf '%s\n' "$1" > "$S/mode.tmp"; mv "$S/mode.tmp" "$S/mode"; }
# Use existing local secrets; never print credentials.
db(){ PYTHONPATH="$H/.secrets/bot3cc" "$PY" - "$@" <<'PYCODE'
import sys
from _db_conn_100 import get_connection
operation=sys.argv[1]
with get_connection('bot3cc_trading') as conn:
    cur=conn.cursor()
    cur.execute('SELECT @@hostname, @@server_id, @@global.read_only')
    host,sid,ro=cur.fetchone()
    if sid != 200 or host.upper() != 'WEB-SERVER':
        raise SystemExit('Unexpected database server')
    if operation == 'status':
        print(f'DB={host} server_id={sid} read_only={ro}')
        cur.execute("SELECT n.hostname,n.node_id,n.node_status,COUNT(a.mem_acc) FROM tb_worker_nodes n LEFT JOIN tb_account_assignment a ON a.node_id=n.node_id WHERE n.hostname IN ('node01','node-backup') GROUP BY n.hostname,n.node_id,n.node_status")
        for row in cur: print(*row)
        sys.exit(0)
    if operation == 'accounts':
        cur.execute('SELECT a.mem_acc FROM tb_account_assignment a JOIN tb_worker_nodes n ON n.node_id=a.node_id WHERE n.hostname=%s ORDER BY a.mem_acc',(sys.argv[2],))
        for row in cur: print(row[0])
        sys.exit(0)
    if operation == 'readonly':
        if not ro: raise SystemExit('Web-server is not read-only')
        sys.exit(0)
    if ro: raise SystemExit('Web-server is read-only; promote manually first')
    conn.rollback()
    conn.start_transaction()
    cur.execute("SELECT hostname,node_id FROM tb_worker_nodes WHERE hostname IN ('node01','node-backup') FOR UPDATE")
    nodes=dict(cur.fetchall())
    if len(nodes)!=2: raise SystemExit('Missing worker node')
    if operation == 'writable': conn.rollback(); sys.exit(0)
    if operation == 'down':
        cur.execute("UPDATE tb_worker_nodes SET node_status='down' WHERE node_id=%s",(nodes['node-backup'],))
    elif operation == 'activate':
        expected=set(open(sys.argv[2]).read().splitlines())
        cur.execute('SELECT mem_acc,node_id FROM tb_account_assignment WHERE node_id IN (%s,%s) FOR UPDATE',(nodes['node01'],nodes['node-backup']))
        rows=cur.fetchall()
        if {a for a,n in rows} != expected or not expected: raise SystemExit('Account assignment changed; aborting')
        cur.execute("UPDATE tb_account_assignment SET node_id=%s,assigned_at=NOW(6),assigned_by='failover_swap_management' WHERE node_id=%s",(nodes['node-backup'],nodes['node01']))
        cur.execute("UPDATE tb_worker_nodes SET node_status=CASE WHEN hostname='node-backup' THEN 'active' ELSE 'down' END WHERE hostname IN ('node01','node-backup')")
    else: raise SystemExit('Unknown operation')
    conn.commit()
PYCODE
}
# Build a manifest from the synchronized Docker metadata, not port arithmetic.
manifest(){ "$PY" - "$R" "$IMAGE" <<'PYCODE'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]); image=sys.argv[2]; rows={}; ports=set(); accounts=set()
for line in (r/'state/docker-ps.txt').read_text().splitlines():
    fields=line.split('\t'); name=fields[0]
    if not name.startswith('VPS.'): continue
    if len(fields)!=4 or not re.fullmatch(r'VPS\.[A-Za-z0-9]+\.[A-Za-z0-9_.-]+',name) or fields[1]!=image: raise SystemExit('Invalid VPS metadata: '+name)
    a=re.findall(r'127\.0\.0\.1:(\d+)->4444/tcp',fields[3]); b=re.findall(r'100\.86\.15\.13:(\d+)->7900/tcp',fields[3])
    if len(a)!=1 or len(b)!=1: raise SystemExit('Missing port mapping: '+name)
    p,q=int(a[0]),int(b[0]); acc=name.split('.')[1]
    if not (40000<=p<50000 and 50000<=q<60000) or p in ports or q in ports or acc in accounts or name in rows: raise SystemExit('Duplicate or invalid port/account: '+name)
    ports.update([p,q]); accounts.add(acc); rows[name]=(p,q,acc)
profiles={p.name for p in (r/'volumes').glob('VPS.*') if p.is_dir() and not p.is_symlink()}
if not rows or profiles!=set(rows): raise SystemExit('Profile/metadata mismatch: '+str(profiles.symmetric_difference(rows)))
for name,(p,q,acc) in sorted(rows.items()):
    d=r/'volumes'/name/'Default'
    if not d.is_dir() or d.is_symlink(): raise SystemExit('Missing Default: '+name)
    print(name,p,q,acc,sep='\t')
PYCODE
}
idle(){
    local c out
    if pgrep -u "$(id -u)" -f '[W]orker_Controller\.py|[W]orker_for_SmartOne\.py|[S]martOne_Worker_Stop\.py' >/dev/null; then fail 'SmartOne processes still running; wait until after cutoff.'; fi
    for c in BOT3CC.SSI BOT3CC.SSI-FETCH; do
        if docker container inspect "$c" >/dev/null 2>&1 && [[ $(docker inspect -f '{{.State.Running}}' "$c") == true ]]; then
            out=$(docker top "$c" -eo pid,comm)
            echo "$out"
            [[ $(awk 'NR>1 && $2!="sleep" {n++} END{print n+0}' <<< "$out") == 0 ]] || fail "$c has active processes; finish manually first."
        fi
    done
}
cron_save(){
    local err="$S/cron.err"
    if crontab -l > "$S/cron.original.tmp" 2>"$err"; then echo present > "$S/cron.kind"; elif grep -q 'no crontab for' "$err"; then echo absent > "$S/cron.kind"; else fail 'Cannot read crontab'; fi
    mv "$S/cron.original.tmp" "$S/cron.original"
    rm -f "$err"
    ! grep -q 'BEGIN FAILOVER' "$S/cron.original" || fail 'Existing failover block found'
}
cron_install(){
    { cat "$S/cron.original"; printf '\n# BEGIN FAILOVER\n'; cat "$S/cron.jobs"; printf '\n# END FAILOVER\n'; } > "$S/cron.active"
    crontab "$S/cron.active"
}
cron_restore(){
    [[ -f $S/cron.original && -f $S/cron.kind ]] || fail 'Missing original crontab'
    if [[ $(cat "$S/cron.kind") == present ]]; then crontab "$S/cron.original"; else if crontab -l >/dev/null 2>&1; then crontab -r; fi; fi
}
cron_jobs(){ "$PY" - "$R/state/crontab.txt" <<'PYCODE'
import sys
rules=['/VPS-Automation/run_controller.sh','/VPS-Automation/run_oot_summary.sh','/app/Get_token_for_SSI_accounts.py','/app/Controler_for_SSI.py','/app/ssi_fetch_data_streaming.py']
counts=[0]*len(rules)
for line in open(sys.argv[1]):
    if not line.strip() or line.lstrip().startswith('#'): continue
    matches=[i for i,r in enumerate(rules) if r in line]
    if not matches: continue
    if len(matches)!=1 or len(line.split(None,5))!=6: raise SystemExit('Invalid cron job')
    counts[matches[0]]+=1; print(line.rstrip())
if not all(counts): raise SystemExit('Missing application cron group')
PYCODE
}
status(){
    echo "Mode: $(mode)"; echo "Last sync: $(cat "$R/_LAST_OK" 2>/dev/null || echo missing)"
    db status
    manifest
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    crontab -l || true
}
activate(){
    local m ip name p q acc dir i ready
    m=$(mode); [[ $m == standby || $m == deactivated || $m == activating ]] || fail "Cannot activate from $m"
    echo '2.1 On node01: stop all application jobs and disable scheduled wake/start and rsync. Shut down/fence node01.'
    echo '2.2 On db-server: isolate old primary and all other database writers.'
    echo '2.3 On web-server: pause replication monitor (C:\Python\MyLogs\replication_monitor.pause), verify recovery point, STOP SLAVE, then SET GLOBAL read_only=OFF. Keep old primary fenced.'
    echo 'Ensure all other DB writers are deliberately redirected or stopped; SSI-fetch is already provisioned locally.'
    echo "Last sync: $(cat "$R/_LAST_OK" 2>/dev/null || echo missing)"
    confirm 'Outside trading hours; preparation complete, sync recovery point accepted and NoVNC restricted to trusted tailnet clients?'
    db writable
    idle
    ip=$(tailscale ip -4); [[ $ip =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid Tailscale IP'
    docker image inspect "$IMAGE" ssi-runtime-ssi-runtime:latest >/dev/null
    docker container inspect BOT3CC.SSI-FETCH >/dev/null
    [[ $(docker inspect -f '{{.State.Running}}' BOT3CC.SSI-FETCH) == true ]] || fail 'Start idle SSI-FETCH manually first'
    if [[ $m == standby ]]; then
        [[ -s $R/_LAST_OK ]] || fail 'Missing last successful sync marker'
        manifest > "$S/manifest.tmp"; mv "$S/manifest.tmp" "$S/manifest"
        db accounts node01 | LC_ALL=C sort > "$S/accounts"; db accounts node-backup > "$S/backup.accounts"
        [[ ! -s $S/backup.accounts ]] || fail 'Backup already has assignments'
        diff -u "$S/accounts" <(cut -f4 "$S/manifest" | LC_ALL=C sort) || fail 'Account/profile mismatch'
        while IFS=$'\t' read -r name p q acc; do
            if docker container inspect "$name" >/dev/null 2>&1 || docker volume inspect "$name" >/dev/null 2>&1; then fail "Existing container/volume: $name"; fi
        done < "$S/manifest"
        if docker container inspect BOT3CC.SSI >/dev/null 2>&1; then fail 'Existing SSI runtime container'; fi
        cron_save; cron_jobs > "$S/cron.jobs"
        cat "$S/cron.jobs"
        confirm 'Use these application cron jobs and restore source with rsync --delete (logs preserved)?'
        setmode activating
    else
        [[ -s $S/manifest && -s $S/accounts && -f $S/cron.original ]] || fail 'Missing session state'
        cron_restore
    fi
    setmode activating
    echo '2.4 Restore application source and prepare named volumes.'
    for name in VPS-Automation ssi-runtime; do
        [[ -d $R/env/$name && ! -L $R/env/$name && -d $H/$name && ! -L $H/$name ]] || fail "Invalid source/destination: $name"
        rsync -a --delete --exclude='/logs/' "$R/env/$name/" "$H/$name/"
        mkdir -p "$H/$name/logs"
    done
    "$PY" -m pip check
    sudo -v
    while IFS=$'\t' read -r name p q acc; do
        dir="$R/volumes/$name"; [[ -d $dir && ! -L $dir ]] || fail "Invalid profile: $dir"
        sudo chown -Rh 1200:1201 -- "$dir"
        if ! docker volume inspect "$name" >/dev/null 2>&1; then docker volume create --driver local --opt type=none --opt o=bind --opt device="$dir" "$name" >/dev/null; fi
        [[ $(docker volume inspect -f '{{index .Options "device"}}' "$name") == "$dir" ]] || fail "Wrong volume: $name"
        if ! docker container inspect "$name" >/dev/null 2>&1; then
            docker create --name "$name" --label bot3cc.failover=true --restart always --shm-size=2g -e TZ=UTC -e SE_VNC_NO_PASSWORD=true -p "127.0.0.1:$p:4444" -p "$ip:$q:7900" -v "$name:/home/seluser/profile" "$IMAGE" >/dev/null
        fi
        [[ $(docker inspect -f '{{index .Config.Labels "bot3cc.failover"}}' "$name") == true ]] || fail "Unmanaged container: $name"
        docker start "$name" >/dev/null
    done < "$S/manifest"
    echo '2.5 Verify Selenium readiness and start idle SSI runtime.'
    while IFS=$'\t' read -r name p q acc; do
        ready=0
        for ((i=0;i<30;i++)); do
            if curl -fsS --max-time 3 "http://127.0.0.1:$p/status" | "$PY" -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["value"]["ready"] else 1)' 2>/dev/null; then ready=1; break; fi
            sleep 2
        done
        [[ $ready == 1 ]] || fail "Selenium not ready: $name"
    done < "$S/manifest"
    (cd "$H/ssi-runtime"; docker compose up -d --no-build --pull never)
    idle
    echo '2.6 Transfer account assignment on web-server; enable scheduled jobs last.'
    confirm 'All containers ready; authorize DB assignment and cron activation?'
    db activate "$S/accounts"
    cron_install
    setmode active
    echo 'ACTIVE. Jobs will run at their next scheduled times; no immediate worker launch.'
}
deactivate(){
    local name p q acc
    [[ $(mode) == active || $(mode) == activating || $(mode) == deactivating || $(mode) == deactivated ]] || fail 'Invalid state for Deactivate'
    confirm 'Outside trading hours; stop scheduling and deactivate backup?'
    setmode deactivating
    cron_restore
    echo '3.1 Original crontab restored. Wait for current jobs to finish; close any manual Chrome sessions.'
    idle
    confirm 'All workloads finished and Chrome sessions closed?'
    echo '3.2 Stop Selenium and SSI runtime; keep profiles and assignments.'
    while IFS=$'\t' read -r name p q acc; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            [[ $(docker inspect -f '{{index .Config.Labels "bot3cc.failover"}}' "$name") == true ]] || fail "Unmanaged container: $name"
            docker stop "$name" >/dev/null
        fi
    done < "$S/manifest"
    if docker container inspect BOT3CC.SSI >/dev/null 2>&1; then docker stop BOT3CC.SSI >/dev/null; fi
    # SSI-FETCH remains an idle pre-existing container.
    db down
    setmode deactivated
    echo 'DEACTIVATED. Web-server remains primary; assignments unchanged.'
}
swapback(){
    local name p q acc dir
    [[ $(mode) == deactivated || $(mode) == swapping ]] || fail 'Deactivate successfully first'
    idle
    cron_restore
    setmode swapping
    echo '4.1 Keep node01 jobs/rsync disabled. Stop all writers to web-server, including external applications.'
    echo '4.2 On web-server: retain a consistent backup of all affected databases and exact binlog coordinates. Keep replication monitor paused.'
    echo '4.3 On db-server: back up existing databases, restore the authoritative web-server snapshot while isolated. Do not overwrite mysql system schema blindly.'
    echo '4.4 On db-server, after verifying restored data, execute the following transaction manually:'
    cat <<'SQL'
START TRANSACTION;
UPDATE bot3cc_trading.tb_account_assignment a
JOIN bot3cc_trading.tb_worker_nodes b ON b.node_id=a.node_id AND b.hostname='node-backup'
JOIN bot3cc_trading.tb_worker_nodes n ON n.hostname='node01'
SET a.node_id=n.node_id,a.assigned_at=NOW(6),a.assigned_by='swap-back';
SELECT ROW_COUNT() AS transferred_accounts;
UPDATE bot3cc_trading.tb_worker_nodes SET node_status=CASE WHEN hostname='node01' THEN 'active' ELSE 'down' END WHERE hostname IN ('node01','node-backup');
-- Verify assignments and count before COMMIT; otherwise ROLLBACK.
SELECT n.hostname,COUNT(*) FROM bot3cc_trading.tb_account_assignment a JOIN bot3cc_trading.tb_worker_nodes n ON n.node_id=a.node_id WHERE n.hostname IN ('node01','node-backup') GROUP BY n.hostname;
SQL
    echo "Expected transferred accounts: $(wc -l < "$S/accounts"). COMMIT only after checking."
    echo '4.5 Re-establish web-server as read-only replica from a verified matching snapshot/position on db-server. Never reuse historical positions. Coordinate downstream replicas. Keep all workloads and rsync stopped until cleanup finishes.'
    confirm 'DB restore, assignment, replication and read-only verified manually?'
    db readonly
    db accounts node01 | LC_ALL=C sort > "$S/returned.accounts"; db accounts node-backup > "$S/remaining.accounts"
    [[ ! -s $S/remaining.accounts ]] || fail 'Backup still has assigned accounts'
    diff -u "$S/accounts" "$S/returned.accounts" || fail 'Returned accounts differ'
    echo '4.6 Remove only failover containers and bind-volume definitions. Keep original profile directories.'
    sudo -v
    while IFS=$'\t' read -r name p q acc; do
        dir="$R/volumes/$name"; [[ -d $dir && ! -L $dir ]] || fail "Invalid profile: $dir"
        if docker container inspect "$name" >/dev/null 2>&1; then
            [[ $(docker inspect -f '{{index .Config.Labels "bot3cc.failover"}}' "$name") == true && $(docker inspect -f '{{.State.Running}}' "$name") == false ]] || fail "Unsafe container: $name"
            docker rm "$name" >/dev/null
        fi
        if docker volume inspect "$name" >/dev/null 2>&1; then
            [[ $(docker volume inspect -f '{{index .Options "device"}}' "$name") == "$dir" ]] || fail "Wrong volume: $name"
            docker volume rm "$name" >/dev/null
        fi
        [[ -d $dir/Default ]] || fail "Profile missing: $dir"
        sudo chown -Rh node-admin:node-admin -- "$dir"
    done < "$S/manifest"
    if docker container inspect BOT3CC.SSI >/dev/null 2>&1; then
        [[ $(docker inspect -f '{{.State.Running}}' BOT3CC.SSI) == false ]] || fail 'SSI still running'
        docker rm BOT3CC.SSI >/dev/null
    fi
    setmode standby
    echo '4.7 STANDBY. On node01: restore normal job scheduling and one-way rsync; on web-server resume replication monitor after checking health. No profiles copied back.'
}
# Each operation runs in a subshell so failures return to the menu.
while true; do
    printf '\nBOT3CC Failover Swap Management (%s)\n1. Status\n2. Activate\n3. Deactivate\n4. Swap-back\n0. Exit\n' "$(mode)"
    read -r -p 'Select: ' choice || exit 0
    case $choice in 1) action=status;; 2) action=activate;; 3) action=deactivate;; 4) action=swapback;; 0) exit 0;; *) continue;; esac
    set +e
    (set -Eeuo pipefail; "$action")
    rc=$?
    set -e
    if ((rc)); then echo "Operation stopped (rc=$rc). Review state before retrying."; fi
done
