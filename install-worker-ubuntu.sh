#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}
DOCKER_VERSION="17.06.2"
################################################################################
### Packages ###################################################################
################################################################################

# Update the OS to begin with to catch up to the latest packages.
sudo apt-get update -y

# Install necessary packages
sudo apt-get install -y \
    conntrack \
    curl \
    socat \
    unzip \
    wget \
    vim \
    python \
    python-pip \
    apt-transport-https \
    ca-certificates \
    software-properties-common \
    nfs-common

sudo pip install --upgrade awscli

################################################################################
### iptables ###################################################################
################################################################################

# Enable forwarding via iptables
sudo iptables -P FORWARD ACCEPT
sudo bash -c "/sbin/iptables-save > /etc/sysconfig/iptables"

sudo mv $TEMPLATE_DIR/iptables-restore.service /etc/systemd/system/iptables-restore.service

sudo systemctl daemon-reload
sudo systemctl enable iptables-restore

################################################################################
### Docker #####################################################################
################################################################################

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu xenial stable"
sudo apt-get update -y
sudo apt-get install -y docker-ce=$(apt-cache madison docker-ce | grep ${DOCKER_VERSION} | head -n 1 | cut -d ' ' -f 4)
sudo usermod -aG docker $USER

# Enable docker daemon to start on boot.
sudo systemctl daemon-reload
sudo systemctl enable docker


################################################################################
### Logrotate ##################################################################
################################################################################

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $TEMPLATE_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d

CNI_VERSION=${CNI_VERSION:-"v0.6.0"}
wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-amd64-${CNI_VERSION}.tgz
sudo tar -xvf cni-amd64-${CNI_VERSION}.tgz -C /opt/cni/bin
rm cni-amd64-${CNI_VERSION}.tgz

CNI_PLUGIN_VERSION=${CNI_PLUGIN_VERSION:-"v0.7.1"}
wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz
sudo tar -xvf cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz -C /opt/cni/bin
rm cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz

echo "Downloading binaries from: s3://$BINARY_BUCKET_NAME"
S3_DOMAIN="s3-$BINARY_BUCKET_REGION"
if [ "$BINARY_BUCKET_REGION" = "us-east-1" ]; then
    S3_DOMAIN="s3"
fi
S3_URL_BASE="https://$S3_DOMAIN.amazonaws.com/$BINARY_BUCKET_NAME/$BINARY_BUCKET_PATH"
wget $S3_URL_BASE/kubelet
wget $S3_URL_BASE/kubectl
wget $S3_URL_BASE/heptio-authenticator-aws

chmod +x kubectl kubelet heptio-authenticator-aws
sudo mv kubectl kubelet heptio-authenticator-aws /usr/bin/

sudo mv $TEMPLATE_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo mv $TEMPLATE_DIR/kubelet.service /etc/systemd/system/kubelet.service

sudo systemctl daemon-reload
sudo systemctl enable kubelet

# Clean up yum caches to reduce the image size
sudo apt-get clean
