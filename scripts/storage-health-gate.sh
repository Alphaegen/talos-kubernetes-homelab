#!/usr/bin/env bash

set -euo pipefail

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
}

not_ready_nodes="$(kubectl get nodes -o json | jq -r '.items[] | select(any(.status.conditions[]; .type == "Ready" and .status != "True")) | .metadata.name')"
if [[ -n "$not_ready_nodes" ]]; then
  fail "Kubernetes nodes are not ready: ${not_ready_nodes//$'\n'/, }"
else
  pass "all Kubernetes nodes are ready"
fi

while read -r node _cpu _cpu_percentage _memory memory_percentage; do
  memory_percentage="${memory_percentage%%%}"
  if (( memory_percentage >= 85 )); then
    fail "$node memory usage is ${memory_percentage}% of allocatable"
  else
    pass "$node memory usage is below 85% (${memory_percentage}%)"
  fi
done < <(kubectl top nodes --no-headers)

for daemonset_ref in kube-system/cilium longhorn-system/longhorn-manager longhorn-system/longhorn-csi-plugin; do
  namespace="${daemonset_ref%%/*}"
  daemonset="${daemonset_ref#*/}"
  unavailable="$(kubectl get daemonset "$daemonset" -n "$namespace" -o jsonpath='{.status.numberUnavailable}')"
  unavailable="${unavailable:-0}"
  if [[ "$unavailable" != "0" ]]; then
    fail "$daemonset has $unavailable unavailable pod(s)"
  else
    pass "$daemonset is available on every scheduled node"
  fi
done

bad_instance_managers="$(kubectl get instancemanagers.longhorn.io -n longhorn-system -o json | jq -r '.items[] | select(.status.currentState != "running") | .metadata.name')"
if [[ -n "$bad_instance_managers" ]]; then
  fail "Longhorn instance managers are not running: ${bad_instance_managers//$'\n'/, }"
else
  pass "all Longhorn instance managers are running"
fi

bad_volumes="$(kubectl get volumes.longhorn.io -n longhorn-system -o json | jq -r '.items[] | select(.status.robustness == "faulted" or .status.robustness == "degraded") | .metadata.name')"
if [[ -n "$bad_volumes" ]]; then
  fail "Longhorn volumes need attention: ${bad_volumes//$'\n'/, }"
else
  pass "no Longhorn volumes are faulted or degraded"
fi

for setting_check in \
  "auto-delete-pod-when-volume-detached-unexpectedly|true" \
  "node-down-pod-deletion-policy|delete-both-statefulset-and-deployment-pod" \
  "concurrent-replica-rebuild-per-node-limit|1" \
  "concurrent-volume-backup-restore-per-node-limit|1" \
  "backup-concurrent-limit|1" \
  "restore-concurrent-limit|1"; do
  setting="${setting_check%%|*}"
  expected="${setting_check#*|}"
  actual="$(kubectl get settings.longhorn.io "$setting" -n longhorn-system -o jsonpath='{.value}')"
  if [[ "$actual" != "$expected" ]]; then
    fail "Longhorn setting $setting is $actual; expected $expected"
  else
    pass "Longhorn setting $setting is $expected"
  fi
done

backup_available="$(kubectl get backuptargets.longhorn.io default -n longhorn-system -o jsonpath='{.status.available}')"
if [[ "$backup_available" != "true" ]]; then
  fail "Longhorn backup target is unavailable"
else
  pass "Longhorn backup target is available"
fi

unbacked_attached_volumes="$(kubectl get volumes.longhorn.io -n longhorn-system -o json | jq -r '.items[] | select(.status.state == "attached" and (.status.lastBackup == null or .status.lastBackup == "")) | .metadata.name')"
if [[ -n "$unbacked_attached_volumes" ]]; then
  fail "attached volumes have no successful backup: ${unbacked_attached_volumes//$'\n'/, }"
else
  pass "every attached Longhorn volume has a successful backup"
fi

backup_suspended="$(kubectl get cronjob backup-all -n longhorn-system -o jsonpath='{.spec.suspend}')"
if [[ "$backup_suspended" == "true" ]]; then
  fail "the backup-all CronJob is suspended"
else
  pass "the backup-all CronJob is enabled"
fi

recovery_tickets="$(kubectl get volumeattachments.longhorn.io -n longhorn-system -o json | jq -r '.items[] | select(.spec.attachmentTickets["offline-recovery"] != null) | .metadata.name')"
if [[ -n "$recovery_tickets" ]]; then
  fail "offline recovery tickets still exist: ${recovery_tickets//$'\n'/, }"
else
  pass "no offline recovery tickets remain"
fi

if (( failures > 0 )); then
  printf '\nStorage health gate failed with %d issue(s).\n' "$failures" >&2
  exit 1
fi

printf '\nStorage health gate passed.\n'
