#!/usr/bin/env bash
# Usage: ./deploy.sh [up|status|down]     (run in the folder with the .yaml files)
# Run ./prep-env.sh once per machine (addons + host folders + StorageClass/PV).
set -e
K="microk8s kubectl"
NS=manifest-demo
HERE="$(cd "$(dirname "$0")" && pwd)"
case "${1:-up}" in
  up)
    if [[ -x "$HERE/prep-env.sh" ]]; then
      "$HERE/prep-env.sh"
    else
      microk8s enable hostpath-storage >/dev/null 2>&1 || true
    fi
    $K create namespace $NS --dry-run=client -o yaml | $K apply -f -
    for f in 0*.yaml; do echo "--> $f"; $K apply -n $NS -f "$f"; done
    echo; $K get all,pvc,ingress,networkpolicy,sa -n $NS
    echo; $K get pv,sc
    echo
    echo "Open from this workstation (browser or curl):"
    echo "  hello-pod        curl http://localhost:30082"
    echo "  web deployment   curl http://localhost:30080"
    echo "  ports-demo       curl http://localhost:30081"
    echo "  statefulset      curl http://localhost:30083"
    echo "  daemonset        curl http://localhost:30084"
    echo "  volumes-demo     curl http://localhost:30085"
    echo "  dns-test         curl http://localhost:30086"
    echo "  ingress          curl http://localhost:80"
    echo "  ingress + host   curl http://localhost:80 -H \"Host: web.local\""
    ;;
  status) $K get all,pvc,ingress,networkpolicy -n $NS; $K get pv,sc ;;
  down)   $K delete namespace $NS
          $K delete pv academy-pv-1gi --ignore-not-found
          ;;
  *) echo "Use: $0 [up|status|down]"; exit 1 ;;
esac
