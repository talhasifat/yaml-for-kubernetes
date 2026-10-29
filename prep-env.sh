#!/usr/bin/env bash
# prep-env.sh — make MicroK8s ready for the classroom YAML demos.
# Run inside WSL on the machine where MicroK8s is installed.
#
#   chmod +x prep-env.sh create-dev-user.sh deploy.sh
#   ./prep-env.sh
#
# What this does:
#   1. Wait until MicroK8s is ready (CNI = Calico, already there)
#   2. Enable DNS (CoreDNS), hostpath-storage, ingress (nginx), metrics-server
#   3. Create host folders used by static PV / hostPath / DaemonSet
#   4. Apply foundation manifests (StorageClass, PV, PVC, ConfigMap, Secret, RBAC)
set -euo pipefail

K="microk8s kubectl"
HERE="$(cd "$(dirname "$0")" && pwd)"
STORE="/var/snap/microk8s/common/academy-storage"

need_microk8s() {
  if ! command -v microk8s >/dev/null 2>&1; then
    echo "microk8s not found. Install it in WSL first:"
    echo "  sudo snap install microk8s --classic"
    echo "  sudo usermod -aG microk8s \"\$USER\" && newgrp microk8s"
    exit 1
  fi
}

echo "==> Waiting for MicroK8s (CNI/Calico comes with the install)"
need_microk8s
microk8s status --wait-ready

echo "==> Enabling addons: dns, hostpath-storage, ingress, metrics-server, rbac"
# dns              -> CoreDNS (Service names like web.manifest-demo.svc.cluster.local)
# hostpath-storage -> StorageClass microk8s-hostpath (StatefulSet PVCs)
# ingress          -> nginx Ingress controller, class name "public"
# rbac             -> Role / RoleBinding / ClusterRole (usually already on)
# metrics-server   -> kubectl top (optional, ignore if it fails)
microk8s enable dns
microk8s enable hostpath-storage
microk8s enable ingress
microk8s enable rbac >/dev/null 2>&1 || true
microk8s enable metrics-server >/dev/null 2>&1 || true

echo "==> Creating hostPath / PV directories"
sudo mkdir -p \
  "$STORE/pv1" \
  "$STORE/hostpath-demo" \
  "$STORE/node-agent"
sudo chmod -R 0777 "$STORE"

echo "==> Waiting for StorageClass and CoreDNS"
for i in $(seq 1 30); do
  if $K get sc microk8s-hostpath >/dev/null 2>&1 \
     && $K -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q Running; then
    break
  fi
  sleep 2
done

echo "==> Applying foundation YAML (namespace-independent / cluster pieces first)"
$K apply -f "$HERE/11-storageclass.yaml"
$K apply -f "$HERE/12-pv.yaml"

echo
echo "Cluster primitives:"
$K get sc
$K get pv
echo
$K -n kube-system get pods -l k8s-app=kube-dns
echo
$K -n ingress get pods 2>/dev/null || echo "(ingress pods appear in namespace 'ingress')"
echo
echo "Next:"
echo "  ./deploy.sh up                         # workloads + ConfigMap/Secret/PVC/Ingress/DNS demo"
echo "  sudo ./create-dev-user.sh alice alice-lab   # SSH user + namespace-scoped kubeconfig"
echo
echo "Quick checks:"
echo "  microk8s kubectl get nodes"
echo "  microk8s kubectl get sc,pv"
echo
echo "After ./deploy.sh up, from this workstation:"
echo "  curl http://localhost:30080            # web (NodePort)"
echo "  curl http://localhost:80               # ingress"
