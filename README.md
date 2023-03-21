# Worker Images
This repository stores the code used to create a machine image for use in [Taskcluster](https://github.com/taskcluster). This repository uses Packer to provision the machine image, and the windows packer machine images use [Powershell Packer Provisioner](https://developer.hashicorp.com/packer/docs/provisioners/powershell) to call a custom script which bootstrap the OS using [Puppet](https://www.puppet.com/docs/puppet/7/puppet_index.html).

## Acronyms

* GHA = Github Actions
* TC = Taskcluster, the CI pipeline to build and release Firefox.
* Worker Image = A machine image for use with Taskcluster that contains configuration from puppet.
* Ronin Puppet = Git repository that contains [puppet code](https://github.com/mozilla-platform-ops/ronin_puppet) which configures each worker image with specific configuration 

### Todo

- [ ] Software Bill of Materials [(RELOPS-311)](https://mozilla-hub.atlassian.net/browse/RELOPS-311)
- [ ] Schedule automated "builds" with beta pools [(RELOPS-413)](https://mozilla-hub.atlassian.net/browse/RELOPS-413)
- [ ] Create "release" artifact with changelog, software list, etc (similar to [runner-images release method](https://github.com/actions/runner-images/releases))
- [ ] Create audit task script in-tree (Mark)
- [ ] For "source" pools, figure out an automated way to provision a template with source code baked in and regularly built via github actions
- [ ] After image is created/released, trigger try/push with sample tasks (mochitest chrome, etc) and run audit task.
- [ ] Github Actions
  - [ ] [OIDC Azure](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure) | [(RELOPS-309)](https://mozilla-hub.atlassian.net/browse/RELOPS-309)
  - [ ] [OIDC Google Cloud Platform](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-google-cloud-platform) | [(RELOPS-399)](https://mozilla-hub.atlassian.net/browse/RELOPS-399)
  - [ ] Parallel support for packer in GHA | [(RELOPS-312)](https://mozilla-hub.atlassian.net/browse/RELOPS-312)

### In Progress


### Done ✓

