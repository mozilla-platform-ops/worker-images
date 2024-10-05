# Worker Images

This repository contains an opinionated way to build virtual machine images via packer by using configuration that is pre-defined in YAML format, executed through github actions, with support for automated integration tests using [Pester](https://pester.dev/).

## Features

- Packer variables provided through configuration yaml files
- Supports Windows 10 and Windows 11
- Integration with Pester with configuration yaml files
- Azure Authentication using [OpenID Connect](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure)

## Repository structure

`.github/*` - Github Action Workflows

`bin/WorkerImages` - Powershell Module that provides helper functions to start packer with pre-defined variables

`config` - Worker Pool Definition that Packer uses for varibles

`provisioners` - Internal directory used for non-cloud worker deployments at Mozilla

`scripts/*` - OS specific directories that host either shell scripts or a powershell module to support provisioning and configuring windows 

`tests/win/*` - Windows integration tests written for use with Pester 

`azure.pkr.hcl` - Packer HCL template used for building an Azure Managed Image or Azure Managed Image in a Shared Image Gallery

## Future plans

- Support non-windows platforms
- Integrate with other Mozilla Release Engineering repositories
- Consolidate github action workflow into reusable workflows
- Create better documentation for local debugging
- Create better workflow for multiple branches

## Acronyms

* GHA = Github Actions
* TC = Taskcluster, the CI pipeline to build and release Firefox.
* Worker Image = A machine image for use with Taskcluster.
* Ronin Puppet = Git repository that contains [puppet code](https://github.com/mozilla-platform-ops/ronin_puppet) which configures each worker image with specific configuration 
