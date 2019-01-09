## eks-cis-ami

This is a tweaked fork (to work on AL2 `2017.12`) of [ami-builder-packer](https://github.com/awslabs/ami-builder-packer) with most of [amazon-eks-ami](https://github.com/awslabs/amazon-eks-ami) pulled in. This repo also allows hardened Ubuntu 16.04 and Ubuntu 18.04 AMIs to be built. 

If you don't want to apply CIS hardening, remove the Ansible provisioner from [eks-worker.tpl](eks-worker.tpl)

If you are using 18.04, you need to tell kubelet to point to a different resolv.conf so [DNS does not break for pods](https://github.com/coredns/coredns/issues/1986) - IMO this should be done with a kubelet arg. If you use the `terraform-aws-eks` module, you can do this by passing `kubelet_extra_args` to your worker groups:

```
locals {
  worker_groups = [
    {
      ...
      kubelet_extra_args = "--resolv-conf=/run/systemd/resolve/resolv.conf"
      ...
    }
  ]
}
```

## To build:

1. Clone this repo
2. Update the root password hash in [ubuntu.yaml](ansible/ubuntu.yaml)
    * CIS disables remote root login so it doesn't REALLY matter, but you should at least know the password.
3. Run the build script for your desired AMI:
    * `./build ubuntu16 <YOUR build subnet>`
    * `./build ubuntu18 <YOUR build subnet>` (FYI that Ubuntu 18.04 installs docker 18.06-ce)
    * `./build al2 <YOUR build subnet>`

## Modifications

I dont recommend modifying any of the EKS stuff - it should just work out of the box. However if you want to exlude CIS rules, add them to `cis_level_1_exclusions` or `cis_level_2_exlusions`. To exclude rules for Ubuntu, it's not as easy - you will have to go into the section task file and modify/comment the task(s). 

There are certain things disabled already for compatibility with Kubernetes or to leave it open to customization.

## Todo

* Would be nice to consolidate the codebase - i.e. one packer config, one install script, shared files, etc
