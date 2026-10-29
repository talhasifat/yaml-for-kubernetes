#!/usr/bin/env bash
# create-dev-user.sh — Linux SSH user + Kubernetes namespace + limited kubeconfig.
#
# Run as root on the WSL MicroK8s machine:
#   sudo ./create-dev-user.sh
#   sudo ./create-dev-user.sh alice alice-lab
#
# The developer then:
#   ssh -i alice_id_ed25519 alice@<wsl-ip>
#   kubectl get pods          # only inside their namespace
set -euo pipefail

K="microk8s kubectl"
SA_NAME="dev-sa"
CLUSTER_ROLE="academy-dev-cluster-read"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root:  sudo $0 [developer] [namespace]"
  exit 1
fi

if ! command -v microk8s >/dev/null 2>&1; then
  echo "microk8s not found on this machine."
  exit 1
fi
microk8s status --wait-ready >/dev/null

# ---- input ----
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: sudo $0 [developer_name] [namespace]"
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  DEV_NAME="$1"
else
  read -r -p "Developer name (Linux login, e.g. alice): " DEV_NAME
fi
if [[ -n "${2:-}" ]]; then
  NS="$2"
else
  read -r -p "Kubernetes namespace (e.g. alice-lab): " NS
fi

DEV_NAME="$(echo "$DEV_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
NS="$(echo "$NS" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"

if [[ ! "$DEV_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Invalid developer name. Use lowercase letters, digits, _ or - (start with a letter)."
  exit 1
fi
if [[ ! "$NS" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Invalid namespace. Use DNS-1123 (lowercase, digits, dashes)."
  exit 1
fi

HOME_DIR="/home/${DEV_NAME}"
echo "==> Developer=${DEV_NAME}  namespace=${NS}"

# ---- Linux user + SSH key ----
if id "$DEV_NAME" >/dev/null 2>&1; then
  echo "==> OS user ${DEV_NAME} already exists (keeping home directory)"
else
  useradd -m -s /bin/bash "$DEV_NAME"
  echo "==> Created OS user ${DEV_NAME}"
fi

getent group k8s-devs >/dev/null || groupadd k8s-devs
usermod -aG k8s-devs "$DEV_NAME"
# Do NOT add the user to group 'microk8s' — that group is cluster-admin.
# They will use kubectl + a namespace-scoped kubeconfig instead.

install -d -m 0700 -o "$DEV_NAME" -g "$DEV_NAME" "${HOME_DIR}/.ssh"
KEY_FILE="${HOME_DIR}/.ssh/id_ed25519"
if [[ ! -f "$KEY_FILE" ]]; then
  sudo -u "$DEV_NAME" ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "${DEV_NAME}@microk8s-class"
fi
cat "${KEY_FILE}.pub" > "${HOME_DIR}/.ssh/authorized_keys"
chmod 600 "${HOME_DIR}/.ssh/authorized_keys"
chown "$DEV_NAME:$DEV_NAME" "${HOME_DIR}/.ssh/authorized_keys"

if command -v openssl >/dev/null 2>&1; then
  PASS="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)"
else
  PASS="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-12)"
fi
echo "${DEV_NAME}:${PASS}" | chpasswd

if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
  echo "NOTE: OpenSSH server is not installed. Students can still:  sudo su - ${DEV_NAME}"
  echo "      To enable SSH:  sudo apt-get update && sudo apt-get install -y openssh-server"
fi

# ---- kubectl on PATH (does not grant extra rights; kubeconfig does) ----
KUBECTL_BIN=""
for c in /snap/microk8s/current/kubectl /snap/bin/microk8s.kubectl; do
  if [[ -x "$c" ]]; then KUBECTL_BIN="$c"; break; fi
done
if [[ -n "$KUBECTL_BIN" && ! -e /usr/local/bin/kubectl ]]; then
  ln -sf "$KUBECTL_BIN" /usr/local/bin/kubectl
fi

# ---- Kubernetes namespace, SA, RBAC ----
echo "==> Creating namespace, ServiceAccount, Role, RoleBinding"
$K create namespace "$NS" --dry-run=client -o yaml | $K apply -f -
$K -n "$NS" create serviceaccount "$SA_NAME" --dry-run=client -o yaml | $K apply -f -

cat <<EOF | $K apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-role
  namespace: ${NS}
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/exec", "pods/portforward", "services", "configmaps", "secrets", "persistentvolumeclaims", "events", "replicationcontrollers"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-rolebinding
  namespace: ${NS}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: dev-role
EOF

# Cluster-wide read of a few objects so 'kubectl get nodes / sc / pv' works in class
cat <<EOF | $K apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTER_ROLE}
rules:
- apiGroups: [""]
  resources: ["nodes", "namespaces", "persistentvolumes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CLUSTER_ROLE}-${DEV_NAME}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${CLUSTER_ROLE}
EOF

# ---- kubeconfig from a long-lived token ----
echo "==> Writing kubeconfig for ${DEV_NAME}"
TOKEN="$($K -n "$NS" create token "$SA_NAME" --duration=8760h)"
SERVER="$($K config view --raw -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$($K config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
if [[ -z "$CA_DATA" && -f /var/snap/microk8s/current/certs/ca.crt ]]; then
  CA_DATA="$(base64 -w 0 /var/snap/microk8s/current/certs/ca.crt 2>/dev/null \
    || base64 /var/snap/microk8s/current/certs/ca.crt | tr -d '\n')"
fi

install -d -m 0700 -o "$DEV_NAME" -g "$DEV_NAME" "${HOME_DIR}/.kube"
cat > "${HOME_DIR}/.kube/config" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: microk8s-cluster
contexts:
- context:
    cluster: microk8s-cluster
    namespace: ${NS}
    user: ${DEV_NAME}
  name: ${DEV_NAME}@microk8s
current-context: ${DEV_NAME}@microk8s
users:
- name: ${DEV_NAME}
  user:
    token: ${TOKEN}
EOF
chmod 600 "${HOME_DIR}/.kube/config"
chown -R "$DEV_NAME:$DEV_NAME" "${HOME_DIR}/.kube"

BASHRC="${HOME_DIR}/.bashrc"
grep -q 'KUBECONFIG' "$BASHRC" 2>/dev/null || cat >> "$BASHRC" <<EOF

# added by create-dev-user.sh
export KUBECONFIG=\$HOME/.kube/config
export NS=${NS}
alias k='kubectl'
echo "Kubernetes namespace: ${NS}   (kubectl get pods)"
EOF
chown "$DEV_NAME:$DEV_NAME" "$BASHRC"

# copy public + private key next to the script so the instructor can hand it out
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/dev-keys"
mkdir -p "$OUT_DIR"
cp "$KEY_FILE" "${OUT_DIR}/${DEV_NAME}_id_ed25519"
cp "${KEY_FILE}.pub" "${OUT_DIR}/${DEV_NAME}_id_ed25519.pub"
chmod 600 "${OUT_DIR}/${DEV_NAME}_id_ed25519"

NODE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "=============================================="
echo " Developer ready"
echo "=============================================="
echo " Linux user : ${DEV_NAME}"
echo " Password   : ${PASS}"
echo " Namespace  : ${NS}"
echo " SSH key    : ${OUT_DIR}/${DEV_NAME}_id_ed25519"
echo " Login      : sudo su - ${DEV_NAME}"
echo " SSH        : ssh -i ${OUT_DIR}/${DEV_NAME}_id_ed25519 ${DEV_NAME}@${NODE_IP:-<wsl-ip>}"
echo
echo " Inside the account:"
echo "   kubectl get pods"
echo "   kubectl apply -f 01-pod.yaml"
echo "   kubectl auth can-i delete deployments"
echo
echo " From this workstation (NodePort / localhost):"
echo "   curl http://localhost:30080"
echo "   curl http://localhost:80"
echo
echo " Token lasts 1 year. Re-run this script to rotate the user and kubeconfig."
echo "=============================================="
