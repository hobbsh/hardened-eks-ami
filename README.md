## eks-cis-ami

This is a tweaked fork (to work on AL2 `2017.12`) of https://github.com/awslabs/ami-builder-packer with most of https://github.com/awslabs/amazon-eks-ami pulled in.

## To build:

1. Clone this repo
2. To make an Ubuntu EKS AMI: `make ubuntu`
3. To make an AmazonLinux2 AMI: `make al2`
4. To make both: `make`

## Modifications

I dont recommend modifying any of the EKS stuff - it should just work out of the box. However if you want to exlude CIS rules, add them to `cis_level_1_exclusions` or `cis_level_2_exlusions`. To exclude rules for Ubuntu, it's not as easy - you will have to go into the section task file and modify/comment the task(s). 

There are certain things disabled already for compatibility with Kubernetes or to leave it open to customization. 
