#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

# Update the OS and install necessary packages
if [ "$OS" == "ubuntu" ]; then
  if [ "$VERSION" == "18.04" ]; then
    DOCKER_PACKAGE="docker.io=17.12.1-0ubuntu1"
  else
    DOCKER_PACKAGE="docker-ce=$(apt-cache madison docker-ce | grep '17.06.2' | head -n 1 | cut -d ' ' -f 4)"
  fi

  #PACKAGE_MANAGER_CLEAN="apt-get clean"
  PACKAGE_MANAGER_CLEAN="/bin/true"
  CACHE_DIR="/var/cache/apt/archives"
  IPTABLES_RULES="/etc/iptables/rules.v4"
  NTP_SERVICE="ntp"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq \
      conntrack \
      curl \
      socat \
      unzip \
      wget \
      vim \
      ntp \
      jq \
      logrotate \
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
  sudo apt-get -y update
  sudo apt-get install -y $DOCKER_PACKAGE
  echo "Docker version is $(sudo docker --version)"

elif [ "$OS" == "al2" ]; then
  PACKAGE_MANAGER_CLEAN="yum clean all"
  CACHE_DIR="/var/cache/yum"
  IPTABLES_RULES="/etc/sysconfig/iptables"
  NTP_SERVICE="ntpd"
  sudo yum update -y
  sudo yum install -y \
      aws-cfn-bootstrap \
      conntrack \
      curl \
      jq \
      ntp \
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

sudo systemctl enable iptables-restore
sudo systemctl enable $NTP_SERVICE

sudo mkdir -p /etc/docker
sudo mv $TEMPLATE_DIR/docker-daemon.json /etc/docker/daemon.json
sudo chown root:root /etc/docker/daemon.json

# Enable docker daemon to start on boot.
sudo systemctl daemon-reload
sudo systemctl enable docker

################################################################################
### Logrotate ##################################################################
################################################################################

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $TEMPLATE_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy
sudo chown root:root /etc/logrotate.d/kube-proxy
sudo mkdir -p /var/log/journal

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin

CNI_VERSION=${CNI_VERSION:-"v0.6.0"}
wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-amd64-${CNI_VERSION}.tgz
wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-amd64-${CNI_VERSION}.tgz.sha512
sudo sha512sum -c cni-amd64-${CNI_VERSION}.tgz.sha512
sudo tar -xvf cni-amd64-${CNI_VERSION}.tgz -C /opt/cni/bin
rm cni-amd64-${CNI_VERSION}.tgz cni-amd64-${CNI_VERSION}.tgz.sha512

CNI_PLUGIN_VERSION=${CNI_PLUGIN_VERSION:-"v0.7.1"}
wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz
wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo sha512sum -c cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo tar -xvf cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz -C /opt/cni/bin
rm cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz.sha512

echo "Downloading binaries from: s3://$BINARY_BUCKET_NAME"
S3_DOMAIN="s3-$BINARY_BUCKET_REGION"
if [ "$BINARY_BUCKET_REGION" = "us-east-1" ]; then
    S3_DOMAIN="s3"
fi
S3_URL_BASE="https://$S3_DOMAIN.amazonaws.com/$BINARY_BUCKET_NAME/$BINARY_BUCKET_PATH"

BINARIES=(
    kubelet
    kubectl
    aws-iam-authenticator
)
for binary in ${BINARIES[*]} ; do
    sudo wget $S3_URL_BASE/$binary
    sudo wget $S3_URL_BASE/$binary.sha256
    sudo sha256sum -c $binary.sha256
    sudo chmod +x $binary
    sudo mv $binary /usr/bin/
done
sudo rm *.sha256

sudo mkdir -p /etc/kubernetes/kubelet
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo mv $TEMPLATE_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo chown root:root /var/lib/kubelet/kubeconfig
sudo mv $TEMPLATE_DIR/kubelet.service /etc/systemd/system/kubelet.service
sudo chown root:root /etc/systemd/system/kubelet.service
sudo mv $TEMPLATE_DIR/kubelet-config.json /etc/kubernetes/kubelet/kubelet-config.json
sudo chown root:root /etc/kubernetes/kubelet/kubelet-config.json


sudo systemctl daemon-reload
# Disable the kubelet until the proper dropins have been configured
sudo systemctl disable kubelet

################################################################################
### EKS ########################################################################
################################################################################

sudo mkdir -p /etc/eks
sudo mv $TEMPLATE_DIR/eni-max-pods.txt /etc/eks/eni-max-pods.txt
sudo mv $TEMPLATE_DIR/bootstrap.sh /etc/eks/bootstrap.sh
sudo chmod +x /etc/eks/bootstrap.sh

################################################################################
### AMI Metadata ###############################################################
################################################################################

BASE_AMI_ID=$(curl -s  http://169.254.169.254/latest/meta-data/ami-id)
cat <<EOF > /tmp/release
BASE_AMI_ID="$BASE_AMI_ID"
BUILD_TIME="$(date)"
BUILD_KERNEL="$(uname -r)"
AMI_NAME="$AMI_NAME"
ARCH="$(uname -m)"
EOF
sudo mv /tmp/release /etc/eks/release
sudo chown root:root /etc/eks/*

################################################################################
### Cleanup ####################################################################
################################################################################

# Clean up yum caches to reduce the image size
sudo $PACKAGE_MANAGER_CLEAN
sudo rm -rf \
    $TEMPLATE_DIR \
    $CACHE_DIR

# Clean up files to reduce confusion during debug
sudo rm -rf \
    /etc/machine-id \
    /etc/ssh/ssh_host* \
    /var/log/secure \
    /var/log/auth.log \
    /var/log/wtmp \
    /var/lib/cloud/sem \
    /var/lib/cloud/data \
    /var/lib/cloud/instance \
    /var/lib/cloud/instances \
    /var/log/cloud-init.log \
    /var/log/cloud-init-output.log

sudo touch /etc/machine-id
