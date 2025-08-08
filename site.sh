# chmod +x site.sh                 # once
# ./site.sh up                     # deploy everything
# ./site.sh status                 # view resources
# ./site.sh down                   # delete workloads (keeps data)
# ./site.sh down --force           # NUKES PVC, PV, VolumeAttachments

#!/usr/bin/env bash
set -euo pipefail
NAMESPACE="wordpress"

FILES_CLUSTER=( "local-path-storage.yaml" )
FILES_APP=( "storage.yaml" "mysql.yaml" "deployment.yaml" )

K=kubectl
usage(){ echo "Usage: $0 {up|down [--force]|status|help}"; exit 1; }

create_ns(){ $K get ns $NAMESPACE >/dev/null 2>&1 || $K create ns $NAMESPACE; }

apply_files(){ local ns=$1; shift; for f; do $K apply $ns -f "$f"; done; }
delete_files(){ local ns=$1; shift; for f; do $K delete $ns -f "$f" --ignore-not-found; done; }

rollout(){ $K -n $NAMESPACE rollout status deploy/$1 --timeout=120s || true; }

#### NEW: force‑wipe PVC, PV, VolumeAttachment finalizers ####################
force_wipe_storage() {
  echo "⚠️  FORCE deleting PVCs, PVs, and VolumeAttachments …"

  # 1. VolumeAttachments (CSI) — patch + delete
  for va in $($K get volumeattachment --no-headers | awk '{print $1}'); do
    echo "• removing finalizer on VolumeAttachment $va"
    $K patch volumeattachment "$va" --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null
    $K delete volumeattachment "$va" --wait=false --ignore-not-found
  done

  # 2. PVCs in the namespace
  for pvc in $($K -n $NAMESPACE get pvc --no-headers | awk '{print $1}'); do
    echo "• removing finalizer on PVC $pvc"
    $K -n $NAMESPACE patch pvc "$pvc" --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null
    $K -n $NAMESPACE delete pvc "$pvc" --grace-period=0 --wait=false
  done

  # 3. Unbound PVs
  for pv in $($K get pv --no-headers | awk '$6=="Released"||$6=="Failed"{print $1}'); do
    echo "• removing finalizer on PV $pv"
    $K patch pv "$pv" --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null
    $K delete pv "$pv" --grace-period=0 --wait=false
  done
}
##############################################################################

deploy() {
  create_ns
  echo "➤ Cluster‑wide objects"; apply_files "" "${FILES_CLUSTER[@]}"
  echo "➤ App objects in $NAMESPACE"; apply_files "-n $NAMESPACE" "${FILES_APP[@]}"
  echo "➤ Waiting for rollouts"; rollout mysql; rollout wordpress
  echo "✅  Up at http://<node‑ip>:30080"
}

destroy() {
  local force="${1:-}"
  echo "➤ Deleting app objects";   delete_files "-n $NAMESPACE" "${FILES_APP[@]}"
  echo "➤ Deleting cluster objects"; delete_files "" "${FILES_CLUSTER[@]}"

  if [[ $force == "--force" ]]; then
    force_wipe_storage
  else
    echo "ℹ️  PVC/PV left intact.  Use '$0 down --force' to wipe them."
  fi
}

status(){
  $K get pods,svc -n $NAMESPACE || true
  echo; $K get pvc,pv -n $NAMESPACE || true
}

case "${1:-help}" in
  up)     deploy ;;
  down)   destroy "${2:-}" ;;
  status) status ;;
  help|*) usage ;;
esac
