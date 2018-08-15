KUBERNETES_VERSION ?= 1.10.3
DATE ?= $(shell date +%Y-%m-%d)
AL2_AMI_ID=ami-8c3848f4
UBUNTU_16_AMI_ID=ami-ba602bc2
UBUNTU_18_AMI_ID=ami-59694f21


all: ubuntu16 ubuntu18 al2

al2:
	packer build -var source_ami_id=$(AL2_AMI_ID) eks-worker-al2.json

ubuntu16: 
	packer build -var source_ami_id=$(UBUNTU_16_AMI_ID) eks-worker-ubuntu.json

ubuntu18: 
	packer build -var source_ami_id=$(UBUNTU_18_AMI_ID) eks-worker-ubuntu.json
