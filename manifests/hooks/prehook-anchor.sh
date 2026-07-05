#!/usr/bin/env bash
# Dry-run mirror of the TVK pre-backup hook in manifests/hook-mssql-anchor.yaml
# (keep the two in sync). Run it against the live launcher pod with:
#   oc -n mssql-vss-lab exec -i <virt-launcher-pod> -c compute -- bash -s < manifests/hooks/prehook-anchor.sh
#
# Takes a COPY_ONLY .bak anchor of demo_db via QGA guest-exec as SYSTEM, then
# verifies it with RESTORE HEADERONLY (logs FirstLSN/LastLSN/IsCopyOnly).
# Guest prerequisites: QGA running; NT AUTHORITY\SYSTEM sysadmin on MSSQLSERVER01;
# D:\SQLBackup exists.
#
# NOTE: safe pre-freeze only. QGA disables guest-exec while fsfrozen, and TVK
# post-hooks run BEFORE the thaw — never call guest-exec from a post-hook.
set -u

DOM=$(virsh list --name | head -n1)
[ -n "$DOM" ] || { echo "prehook: no libvirt domain in this launcher pod" >&2; exit 1; }

# run_sql <label> <guest-exec JSON>: submit, poll to completion, print output
run_sql() {
  local label=$1 req=$2 out pid st
  out=$(virsh qemu-agent-command "$DOM" "$req" 2>&1) || { echo "prehook: $label submit failed: $out" >&2; return 1; }
  pid=$(echo "$out" | grep -o '"pid":[0-9]*' | grep -o '[0-9]*')
  [ -n "$pid" ] || { echo "prehook: $label no pid in reply: $out" >&2; return 1; }
  echo "prehook: $label guest-exec pid=$pid"
  st=""
  for _ in $(seq 1 90); do
    st=$(virsh qemu-agent-command "$DOM" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")
    echo "$st" | grep -q '"exited":true' && break
    sleep 2
  done
  echo "$st" | grep -q '"exited":true' || { echo "prehook: $label timed out" >&2; return 1; }
  echo "$st" | grep -o '"out-data":"[^"]*"' | cut -d'"' -f4 | base64 -d 2>/dev/null || true
  echo "$st" | grep -o '"err-data":"[^"]*"' | cut -d'"' -f4 | base64 -d 2>/dev/null || true
  echo "$st" | grep -q '"exitcode":0' || { echo "prehook: $label sqlcmd exited nonzero" >&2; return 1; }
}

ANCHOR=$(cat <<'EOF'
{"execute":"guest-exec","arguments":{"path":"C:\\Program Files\\Microsoft SQL Server\\Client SDK\\ODBC\\180\\Tools\\Binn\\SQLCMD.EXE","arg":["-S",".\\MSSQLSERVER01","-E","-C","-b","-Q","BACKUP DATABASE demo_db TO DISK=N'D:\\SQLBackup\\tvk-prehook-anchor.bak' WITH COPY_ONLY, INIT, FORMAT"],"capture-output":true}}
EOF
)
VERIFY=$(cat <<'EOF'
{"execute":"guest-exec","arguments":{"path":"C:\\Program Files\\Microsoft SQL Server\\Client SDK\\ODBC\\180\\Tools\\Binn\\SQLCMD.EXE","arg":["-S",".\\MSSQLSERVER01","-E","-C","-b","-W","-s","|","-Q","RESTORE HEADERONLY FROM DISK=N'D:\\SQLBackup\\tvk-prehook-anchor.bak'"],"capture-output":true}}
EOF
)

run_sql "anchor" "$ANCHOR" || exit 1
run_sql "verify" "$VERIFY" || exit 1
echo "prehook: COPY_ONLY anchor taken + verified OK"
