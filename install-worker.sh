#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

# Update the OS and install necessary packages
if [ "$OS" == "ubuntu" ]; then
  if [ "$VERSION" == "18.04" ]; then
    DOCKER_PACKAGE="docker.io"
  else
    DOCKER_PACKAGE="docker-ce=$(apt-cache madison docker-ce | grep '17.06.2' | head -n 1 | cut -d ' ' -f 4)"
  fi

  PACKAGE_MANAGER_CLEAN="apt-get clean"
  IPTABLES_RULES="/etc/iptables/rules.v4"
  sudo apt-get update -y
  sudo apt-get upgrade -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq \
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
      iptables-persistent \
      iptables \
      nfs-common

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  sudo apt-get update -y
  sudo apt-get install -y $DOCKER_PACKAGE

elif [ "$OS" == "al2" ]; then
  PACKAGE_MANAGER_CLEAN="yum clean all"
  IPTABLES_RULES="/etc/sysconfig/iptables"
  sudo yum update -y
  sudo yum install -y \
      aws-cfn-bootstrap \
      conntrack \
      curl \
      socat \
      unzip \
      wget \
      nfs-utils 

  curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py"
  sudo python get-pip.py
  rm get-pip.py

  sudo yum install -y yum-utils device-mapper-persistent-data lvm2 yum-versionlock
  sudo amazon-linux-extras enable docker
  sudo yum install -y docker-17.06*
  sudo yum versionlock add docker
else
  echo "Unknown OS: $OS - Exiting"
  exit 1
fi

#Install awscli
sudo pip install --upgrade awscli

# Setup iptables
sudo iptables -P FORWARD ACCEPT
sudo bash -c "/sbin/iptables-save > $IPTABLES_RULES"
sudo bash -c "sed  's|\${IPTABLES_RULES}|'$IPTABLES_RULES'|' $TEMPLATE_DIR/iptables-restore.tpl > /etc/systemd/system/iptables-restore.service"

# Add user to docker group
sudo usermod -aG docker $USER

# Enable iptables-restore and docker on boot
sudo systemctl daemon-reload
sudo systemctl enable iptables-restore
sudo systemctl enable docker

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $TEMPLATE_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy


# Kubernetes and CNI setup
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

# Clean up caches to reduce the image size
sudo bash -c "${PACKAGE_MANAGER_CLEAN}"
