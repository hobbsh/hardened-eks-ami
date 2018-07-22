## eks-cis-ami

This is a tweaked fork (to work on AL2 `2017.12`) of https://github.com/awslabs/ami-builder-packer with most of https://github.com/awslabs/amazon-eks-ami pulled in.

## To build:

Clone this repo and `make`

## Modifications

I dont recommend modifying any of the EKS stuff - it should just work out of the box. However if you want to exlude CIS rules, add them to `cis_level_1_exclusions` or `cis_level_2_exlusions`

See `ansible/playbook.yaml` for what rules are currently disabled, mostly for incompatability for interference with Kubernetes.
