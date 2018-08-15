## eks-cis-ami

This is a tweaked fork (to work on AL2 `2017.12`) of [ami-builder-packer](https://github.com/awslabs/ami-builder-packer) with most of [amazon-eks-ami](https://github.com/awslabs/amazon-eks-ami) pulled in. This repo also allows hardened Ubuntu 16.04 and Ubuntu 18.04 AMIs to be built. 

## To build:

1. Clone this repo
2. To make an Ubuntu 16.04 EKS AMI: `make ubuntu16`
3. To make an Ubuntu 18.04 EKS AMI: `make ubuntu18`
4. To make an AmazonLinux2 AMI: `make al2`
5. To make all: `make`

## Modifications

I dont recommend modifying any of the EKS stuff - it should just work out of the box. However if you want to exlude CIS rules, add them to `cis_level_1_exclusions` or `cis_level_2_exlusions`. To exclude rules for Ubuntu, it's not as easy - you will have to go into the section task file and modify/comment the task(s). 

There are certain things disabled already for compatibility with Kubernetes or to leave it open to customization.

## Todo

* Would be nice to consolidate the codebase - i.e. one packer config, one install script, shared files, etc
