# Worker Images
This repository stores the code used to create a machine image for use in [Taskcluster](https://github.com/taskcluster). This repository uses Packer to provision the machine image, and the windows packer machine images use [Powershell Packer Provisioner](https://developer.hashicorp.com/packer/docs/provisioners/powershell) to call a custom script which bootstrap the OS using [Puppet](https://www.puppet.com/docs/puppet/7/puppet_index.html).

## Acronyms

* GHA = Github Actions
* TC = Taskcluster, the CI pipeline to build and release Firefox.
* Worker Image = A machine image for use with Taskcluster that contains configuration from puppet.
* Ronin Puppet = Git repository that contains [puppet code](https://github.com/mozilla-platform-ops/ronin_puppet) which configures each worker image with specific configuration 

### Todo

- [ ] Software Bill of Materials [(RELOPS-311)](https://mozilla-hub.atlassian.net/browse/RELOPS-311)
- [ ] Github Actions
  - [ ] [(RELOPS-309)](https://mozilla-hub.atlassian.net/browse/RELOPS-309) - [OIDC Azure](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure)
  - [ ] [OIDC Google Cloud Platform](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-google-cloud-platform)
  - [ ] Parallel support for packer in GHA [(RELOPS-312)](https://mozilla-hub.atlassian.net/browse/RELOPS-312)

### In Progress

- [ ] 

### Done ✓

- [x] 