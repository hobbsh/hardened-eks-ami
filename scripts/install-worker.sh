#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit
IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

################################################################################
### Validate Required Arguments ################################################
################################################################################
validate_env_set() {
    (
        set +o nounset

        if [ -z "${!1}" ]; then
            echo "Packer variable '$1' was not set. Aborting"
            exit 1
        fi
    )
}

validate_env_set BINARY_BUCKET_NAME
validate_env_set BINARY_BUCKET_REGION
validate_env_set DOCKER_VERSION
validate_env_set CNI_VERSION
validate_env_set CNI_PLUGIN_VERSION
validate_env_set KUBERNETES_VERSION
validate_env_set KUBERNETES_BUILD_DATE

################################################################################
### Machine Architecture #######################################################
################################################################################

MACHINE=$(uname -m)
if [ "$MACHINE" == "x86_64" ]; then
    ARCH="amd64"
elif [ "$MACHINE" == "aarch64" ]; then
    ARCH="arm64"
else
    echo "Unknown machine architecture '$MACHINE'" >&2
    exit 1
fi

################################################################################
# Update the OS and install necessary packages
if [ "$OS" == "ubuntu" ]; then
  if [ "$VERSION" == "18.04" ]; then
    DOCKER_PACKAGE="docker-ce=${DOCKER_VERSION}"
  else
    DOCKER_PACKAGE="docker-ce=$(apt-cache madison docker-ce | grep '17.06.2' | head -n 1 | cut -d ' ' -f 4)"
  fi

  #PACKAGE_MANAGER_CLEAN="apt-get clean"
  PACKAGE_MANAGER_CLEAN="/bin/true"
  CACHE_DIR="/var/cache/apt/archives"
  IPTABLES_RULES="/etc/iptables/rules.v4"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq \
      apt-transport-https \
      build-essential \
      ca-certificates \
      checkinstall \
      chrony \
      conntrack \
      curl \
      iptables \
      iptables-persistent \
      jq \
      libbz2-dev \
      libc6-dev \
      libgdbm-dev \
      libncursesw5-dev \
      libreadline-gplv2-dev \
      libsqlite3-dev \
      libssl-dev \
      logrotate \
      nfs-common \
      python3-pip \
      python \
      python-pip \
      socat \
      software-properties-common \
      tk-dev \
      unzip \
      vim \
      wget

  update-rc.d chrony defaults 80 20
  sudo sed -i '1s/^/server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4\n/' /etc/chrony/chrony.conf

  # Ubuntu's package repositories don't use a version of awscli that has eks
  sudo pip3 install awscli

  # Install aws-cfn-bootstrap directly, instead of via apt
  sudo apt-get install -y python2.7
  sudo apt-get install -y python-pip
  sudo pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz

  sudo ln -s /root/aws-cfn-bootstrap-latest/init/ubuntu/cfn-hup /etc/init.d/cfn-hup
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  sudo apt-get -y update
  sudo apt-get install -y $DOCKER_PACKAGE
  echo "Docker version is $(sudo docker --version)"

elif [ "$OS" == "al2" ]; then
  PACKAGE_MANAGER_CLEAN="yum clean all"
  CACHE_DIR="/var/cache/yum"
  IPTABLES_RULES="/etc/sysconfig/iptables"
  sudo yum update -y
  sudo yum install -y \
      aws-cfn-bootstrap \
      awscli \
      chrony \
      conntrack \
      curl \
      jq \
      ec2-instance-connect \
      nfs-utils \
      socat \
      unzip \
      wget

  sudo chkconfig chronyd on

  # Remove the ec2-net-utils package, if it's installed. This package interferes with the route setup on the instance.
  if yum list installed | grep ec2-net-utils; then sudo yum remove ec2-net-utils -y -q; fi

  curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py"
  sudo python get-pip.py
  rm get-pip.py

  sudo yum install -y yum-utils device-mapper-persistent-data lvm2
  sudo amazon-linux-extras enable docker
  sudo groupadd -fog 1950 docker && sudo useradd --gid 1950 docker
  sudo yum install -y docker-${DOCKER_VERSION}*
  # Remove all options from sysconfig docker.
  sudo sed -i '/OPTIONS/d' /etc/sysconfig/docker
else
  echo "Unknown OS: $OS - Exiting"
  exit 1
fi

################################################################################
### Time #######################################################################
################################################################################

# Make sure that chronyd syncs RTC clock to the kernel.
cat <<EOF | sudo tee -a /etc/chrony.conf
# This directive enables kernel synchronisation (every 11 minutes) of the
# real-time clock. Note that it can’t be used along with the 'rtcfile' directive.
rtcsync
EOF

# If current clocksource is xen, switch to tsc
if grep --quiet xen /sys/devices/system/clocksource/clocksource0/current_clocksource &&
  grep --quiet tsc /sys/devices/system/clocksource/clocksource0/available_clocksource; then
    echo "tsc" | sudo tee /sys/devices/system/clocksource/clocksource0/current_clocksource
else
    echo "tsc as a clock source is not applicable, skipping."
fi


################################################################################
### iptables ###################################################################
################################################################################

# Enable forwarding via iptables
sudo iptables -P FORWARD ACCEPT
sudo bash -c "/sbin/iptables-save > $IPTABLES_RULES"
sudo bash -c "sed  's|\${IPTABLES_RULES}|'$IPTABLES_RULES'|' $TEMPLATE_DIR/iptables-restore.tpl > /etc/systemd/system/iptables-restore.service"

sudo systemctl enable iptables-restore

################################################################################
### Docker #####################################################################
################################################################################

INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
if [[ "$INSTALL_DOCKER" == "true" ]]; then
    sudo usermod -aG docker $USER

    sudo mkdir -p /etc/docker
    sudo mv $TEMPLATE_DIR/docker-daemon.json /etc/docker/daemon.json
    sudo chown root:root /etc/docker/daemon.json

    # Enable docker daemon to start on boot.
    sudo systemctl daemon-reload
    sudo systemctl enable docker
fi

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

wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-${ARCH}-${CNI_VERSION}.tgz
wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-${ARCH}-${CNI_VERSION}.tgz.sha512
sudo sha512sum -c cni-${ARCH}-${CNI_VERSION}.tgz.sha512
sudo tar -xvf cni-${ARCH}-${CNI_VERSION}.tgz -C /opt/cni/bin
rm cni-${ARCH}-${CNI_VERSION}.tgz cni-${ARCH}-${CNI_VERSION}.tgz.sha512

wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz
wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo sha512sum -c cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo tar -xvf cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz -C /opt/cni/bin
rm cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512

echo "Downloading binaries from: s3://$BINARY_BUCKET_NAME"
S3_DOMAIN="amazonaws.com"
if [ "$BINARY_BUCKET_REGION" = "cn-north-1" ] || [ "$BINARY_BUCKET_REGION" = "cn-northwest-1" ]; then
    S3_DOMAIN="amazonaws.com.cn"
fi
S3_URL_BASE="https://$BINARY_BUCKET_NAME.s3.$BINARY_BUCKET_REGION.$S3_DOMAIN/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"
S3_PATH="s3://$BINARY_BUCKET_NAME/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"

BINARIES=(
    aws-iam-authenticator
    kubelet
)
for binary in ${BINARIES[*]} ; do
    if [[ ! -z "$AWS_ACCESS_KEY_ID" ]]; then
        echo "AWS cli present - using it to copy binaries from s3."
        aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary .
        aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary.sha256 .
    else
        echo "AWS cli missing - using wget to fetch binaries from s3. Note: This won't work for private bucket."
        sudo wget $S3_URL_BASE/$binary
        sudo wget $S3_URL_BASE/$binary.sha256
    fi
    sudo sha256sum -c $binary.sha256
    sudo chmod +x $binary
    sudo mv $binary /usr/bin/
done
sudo rm *.sha256

KUBERNETES_MINOR_VERSION=${KUBERNETES_VERSION%.*}

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
    /etc/hostname \
    /etc/machine-id \
    /etc/resolv.conf \
    /etc/ssh/ssh_host* \
    /root/.ssh/authorized_keys \
    /var/lib/cloud/data \
    /var/lib/cloud/instance \
    /var/lib/cloud/instances \
    /var/lib/cloud/sem \
    /var/lib/dhclient/* \
    /var/lib/dhcp/dhclient.* \
    /var/lib/yum/history \
    /var/log/cloud-init-output.log \
    /var/log/cloud-init.log \
    /var/log/secure \
    /var/log/wtmp

sudo touch /etc/machine-id
