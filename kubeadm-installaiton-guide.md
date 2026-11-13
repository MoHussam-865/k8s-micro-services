Installation Process

# 1. System Preparation:

> All Nodes.

**Disable swap memory** 

```bash
sudo swapoff -a
sudo sed -i '/swap/s/^/#/' /etc/fstab
```

kubelet will refuse to start if swap is enabled. 

Configure your Linux kernel by loading the overlay and br_netfilter modules, and apply sysctl parameters to ensure proper IPv4 forwarding.

# 2. **Install Container Runtime**:

>All Nodes.

Install your chosen container runtime (e.g., containerd). 

Once installed, ***generate its default configuration file and modify it to enable the SystemdCgroup driver***, ensuring the runtime and kubelet use the same cgroup manager.

# 3. **Install Kubernetes Tools**:

>All Nodes.

Add the official Kubernetes package repository for your Linux distribution. 

Install kubeadm, kubelet, and kubectl, and immediately "hold" or lock these packages to prevent standard system updates from accidentally upgrading them.

# 4. **Initialize the Control Plane**:

> Master Node Only.

Run 

```bash
sudo kubeadm init --pod-network-cidr=<your-cidr>
```

The CIDR block must match the requirements of the CNI plugin you plan to use. When initialization finishes, run the provided commands to copy the 
admin.conf file to your ~/.kube/config 

directory so you can authorize kubectl commands.

# 5. **Install Pod Network Add-on**:

> Master Node Only.

Apply the manifest for your CNI network plugin (e.g., Calico or Flannel) using 

```bash 
kubectl apply -f <plugin.yaml>
```

The nodes in your cluster will remain in a "NotReady" state until this network layer is actively running.

# 6. ***Join the Worker Nodes***:

> Worker Nodes Only.

Execute the kubeadm join command on each worker node. This exact command—which includes the API server IP, secure token, and CA certificate hash—is printed in the terminal at the very end of the master node's kubeadm init process.


# GO
## 1. Prerequisite Configuration (All Nodes)
Kubernetes requires swap memory to be disabled and specific network routing configurations to allow pods to communicate across the network bridge.

```Bash
# Disable swap immediately
sudo swapoff -a
# (Note: Edit /etc/fstab and comment out the swap line to make this persist across reboots)

# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Configure IP routing and forwarding
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

Why this matters: kubelet actively monitors memory and will refuse to start if swap is enabled, as it breaks Kubernetes' ability to accurately allocate resources. The sysctl settings ensure traffic routed to your pod network bridge is properly processed by iptables.
Verification: Run sysctl net.ipv4.ip_forward. It should output net.ipv4.ip_forward = 1.

to ensure it works run: 

```bash
swapon --show
```

it should show empty


## 2. Install Containerd and Kubernetes Tools (All Nodes)
Install the container runtime (containerd) and configure it to use systemd to manage cgroups, followed by the core Kubernetes packages from the official repository.

```Bash
# Install containerd
sudo apt-get update
sudo apt-get install -y containerd apt-transport-https ca-certificates curl gpg

# Configure containerd to use SystemdCgroup
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Add the Kubernetes v1.31 repository (adjust version if needed)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install kubeadm, kubelet, and kubectl
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

Why this matters: Kubernetes and your OS must agree on how to manage process resources (CPU/RAM). Using SystemdCgroup = true aligns containerd with Ubuntu's native systemd manager, preventing instability. Holding the apt packages prevents accidental version mismatches during routine OS updates.
Verification: Run kubeadm version and systemctl status containerd to ensure the binaries are installed and the runtime is active.

## 3. Initialize the Control Plane (Master Node Only)
Choose one machine to be your master node. The CIDR block below (192.168.0.0/16) is the default requirement for the Calico network plugin.

```Bash
# Initialize the cluster
sudo kubeadm init --pod-network-cidr=192.168.0.0/16

# Configure kubectl for your standard user account
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Why this matters: kubeadm init generates all the necessary cryptographic certificates, stands up the API server, etcd database, and controller manager. Copying the admin.conf file grants your current Linux user cryptographic authorization to run kubectl commands.
Verification: Run kubectl get nodes. Your master node will appear in the list, though its status will say NotReady until the next step is complete.

## 4. Deploy Networking and Join Workers
Apply the Container Network Interface (CNI) to the master node, then join your worker nodes to the cluster.

```Bash
# Run ON THE MASTER NODE to install Calico networking
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml

# Run ON EVERY WORKER NODE (Use the exact output from your kubeadm init command)
# Example format:
sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Why this matters: The CNI (Calico) establishes the overlay network that allows Pods on completely different physical servers to talk to each other securely. The join command uses the temporary bootstrap token to securely introduce new worker servers to the master API.
Verification: After a few minutes, run kubectl get nodes on the master. All nodes should now show a status of Ready.


# Script

```bash
# Use on Master
./scr.sh m 

# Use on node
./scr.sh
# then run the join command
```

```bash
#!/bin/bash

set -e

K8S_VERSION="v1.31"
CALICO_VERSION="v3.25.0"

# m = master, anything else = worker
if [[ "$1" == "m" ]]; then
    MASTER=true
else
    MASTER=false
fi


echo "=== Kubernetes setup started ==="


# -------------------------------
# Check root privileges
# -------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this script as root. Use a sudo user."
    exit 1
fi


# -------------------------------
# Disable swap
# -------------------------------

echo "Checking swap..."

if swapon --show | grep -q .; then
    echo "Disabling swap..."
    sudo swapoff -a
    sudo sed -i '/swap/s/^/#/' /etc/fstab
else
    echo "Swap already disabled"
fi


# -------------------------------
# Kernel modules
# -------------------------------

echo "Configuring kernel modules..."

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF


sudo modprobe overlay
sudo modprobe br_netfilter


# -------------------------------
# Sysctl configuration
# -------------------------------

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF


sudo sysctl --system


# -------------------------------
# Install containerd
# -------------------------------

if ! command -v containerd &>/dev/null; then

    echo "Installing containerd..."

    sudo apt update

    sudo apt install -y containerd apt-transport-https ca-certificates curl gpg conntrack


else

    echo "containerd already installed"

fi



# Configure containerd

if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null
then

    echo "Configuring containerd..."

    sudo mkdir -p /etc/containerd

    containerd config default | sudo tee /etc/containerd/config.toml

    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    sudo systemctl restart containerd

fi


sudo systemctl enable containerd



# -------------------------------
# Kubernetes repository
# -------------------------------

if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then

    echo "Adding Kubernetes repository..."

    sudo mkdir -p -m 755 /etc/apt/keyrings


    curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg


    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

fi



# -------------------------------
# Install Kubernetes packages
# -------------------------------

if ! command -v kubeadm &>/dev/null; then

    echo "Installing Kubernetes..."

    sudo apt update

    sudo apt install -y kubelet kubeadm kubectl

    sudo apt-mark hold kubelet kubeadm kubectl

else

    echo "Kubernetes already installed"

fi



# -------------------------------
# Worker node stop here
# -------------------------------

if [[ "$MASTER" != true ]]; then

    echo "Worker node prepared."

    exit 0

fi



# -------------------------------
# Initialize master
# -------------------------------

if [ -f /etc/kubernetes/admin.conf ]; then

    echo "Cluster already initialized."

else

    echo "Initializing Kubernetes cluster..."

    sudo kubeadm init

fi



# -------------------------------
# Configure kubectl
# -------------------------------

mkdir -p $HOME/.kube


if [ ! -f $HOME/.kube/config ]; then

    sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config

    sudo chown $(id -u):$(id -g) $HOME/.kube/config

fi



# -------------------------------
# Install network plugin
# -------------------------------

if ! kubectl get pods -n kube-system | grep -q calico; then

    echo "Installing Calico..."

    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml

else

    echo "Calico already installed"

fi



# -------------------------------
# Generate worker join command
# -------------------------------

echo ""
echo "Worker join command:"
echo ""

kubeadm token create --print-join-command


echo ""
echo "=== Kubernetes setup completed ==="
```

# Haproxy

replace

```bash
sudo kubeadm init
```

with

```bash
sudo kubeadm init \
  --control-plane-endpoint <HAPROXY_SERVER_PRIVATE_IP> \
  --apiserver-advertise-address <MASTER_PRIVATE_IP> \
  --upload-certs \
  --pod-network-cidr=192.168.0.0/16
```

then the join command for workers will be of the form

```bash
sudo kubeadm join <HAPROXY_IP>:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

and for masters

```bash
sudo kubeadm join <HAPROXY_IP>:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH> \
    --control-plane \
    --certificate-key <CERTIFICATE_KEY>
```

you get the `` by running the following command on the first master

```bash
# get --certificate-key
sudo kubeadm init phase upload-certs --upload-certs

# get join command contains --discovery-token-ca-cert-hash and --token
kubeadm token create --print-join-command
```

## Haproxy server setup

install with 

```bash
sudo apt update
sudo apt install -y haproxy
```

minimal config file at `/etc/haproxy/haproxy.cfg`

```text
global
    log /dev/log local0
    maxconn 4000

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 10s
    timeout client 1m
    timeout server 1m

frontend kubernetes
    bind *:6443
    default_backend kube_api

backend kube_api
    balance roundrobin
    option tcp-check

    server master01 172.31.21.28:6443 check
    server master02 172.31.21.109:6443 check
    server master03 172.31.16.238:6443 check
```

validate the file by

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```