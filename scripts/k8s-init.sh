#!/usr/bin/env bash
set -euo pipefail

# ---- Konfigurálható paraméterek (parancssori flag-ek is vannak) ----
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"       # Calico/Fannelhez jó default
MASTER_IP="${MASTER_IP:-}"                  # --master-ip-vel állítható
K8S_SERIES="${K8S_SERIES:-v1.30}"           # pkgs.k8s.io stable v1.30

usage() {
  cat <<EOF
Használat: sudo bash $0 [--pod-cidr CIDR] [--master-ip IP] [--skip-init]
  --pod-cidr     POD háló (alap: 10.244.0.0/16)
  --master-ip    API szerver hirdetett IP-je (ha üres, auto detektálás)
  --skip-init    Ne futtasd a kubeadm init-et (csak előkészítés)
Példa:
  sudo bash $0 --pod-cidr 10.244.0.0/16 --master-ip 192.168.70.11
EOF
}

SKIP_INIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pod-cidr) POD_CIDR="$2"; shift 2;;
    --master-ip) MASTER_IP="$2"; shift 2;;
    --skip-init) SKIP_INIT=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Ismeretlen opció: $1"; usage; exit 1;;
  esac
done

echo "[1/8] Swap kikapcsolása…"
swapoff -a || true
sed -i.bak '/\sswap\s/ s/^/#/' /etc/fstab || true

echo "[2/8] Alap csomagok…"
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release bash-completion

echo "[3/8] Kernel modulok és sysctl…"
modprobe overlay || true
modprobe br_netfilter || true
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system

echo "[4/8] containerd telepítése és konfigurálása…"
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
# SystemdCgroup bekapcsolása a kubelet kompatibilitás miatt
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# crictl endpointok (kényelmi)
cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo "[5/8] Kubernetes repo + kubeadm/kubelet/kubectl…"
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_SERIES}/deb/Release.key \
  | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_SERIES}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# kubectl completion (opcionális)
kubectl completion bash > /etc/bash_completion.d/kubectl || true

if [[ "$SKIP_INIT" -eq 1 ]]; then
  echo "[6/8] Kihagyva: kubeadm init (--skip-init megadva)."
  exit 0
fi

echo "[6/8] Master IP meghatározása…"
if [[ -z "${MASTER_IP}" ]]; then
  # Próbáljuk a 192.168.* hálózati címet; ha nincs, az első nem-loopback IPv4
  MASTER_IP=$(ip -o -4 addr show | awk '/192\.168\./{print $4}' | cut -d/ -f1 | head -n1)
  [[ -z "$MASTER_IP" ]] && MASTER_IP=$(hostname -I | awk '{print $1}')
fi
echo "MASTER_IP: $MASTER_IP"

echo "[7/8] kubeadm init…"
kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --apiserver-advertise-address="${MASTER_IP}"

echo "[8/8] kubeconfig másolás a currens userhez…"
USER_HOME="$(getent passwd ${SUDO_USER:-$USER} | cut -d: -f6)"
mkdir -p "$USER_HOME/.kube"
cp -i /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown $(id -u ${SUDO_USER:-$USER}):$(id -g ${SUDO_USER:-$USER}) "$USER_HOME/.kube/config"

echo "Calico CNI telepítése…"
# Calico (stabil manifest)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml

echo "Join parancsok generálása…"
JOIN_WORKER="$(kubeadm token create --print-join-command)"
CERT_KEY="$(kubeadm init phase upload-certs --upload-certs | tail -n1 || true)"
echo "${JOIN_WORKER}" > /root/join-worker.sh
chmod +x /root/join-worker.sh
if [[ -n "${CERT_KEY}" ]]; then
  echo "${JOIN_WORKER} --control-plane --certificate-key ${CERT_KEY}" > /root/join-master.sh
  chmod +x /root/join-master.sh
fi

cat <<EOF

KÉSZ ✅

• kubeconfig:   $USER_HOME/.kube/config
• worker join:  sudo /root/join-worker.sh
• master join:  sudo /root/join-master.sh     (csak ha több mastert is akarsz)
• CNI:          Calico (POD_CIDR=${POD_CIDR})

Hasznos parancsok:
  kubectl get nodes -o wide
  kubectl get pods -n kube-system
EOF
