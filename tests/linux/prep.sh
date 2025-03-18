#!/bin/bash

# Get the machine architecture
arch=$(uname -m)

case "$arch" in
    x86_64)
        echo "Detected x86_64 architecture. Installing PowerShell on Ubuntu..."

        # Update the list of packages
        apt-get update

        # Install pre-requisite packages.
        apt-get install -y wget apt-transport-https software-properties-common

        # Source Ubuntu version details
        source /etc/os-release

        # Download the Microsoft repository keys
        wget -q https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb

        # Register the Microsoft repository keys
        dpkg -i packages-microsoft-prod.deb

        # Delete the repository keys file
        rm packages-microsoft-prod.deb

        # Update the list of packages after adding the Microsoft repo
        apt-get update

        # Install PowerShell
        apt-get install -y powershell
        ;;
    arm*|aarch64)
        echo "Detected ARM architecture. Installing PowerShell on Arm64 Ubuntu..."
        # Download the powershell '.tar.gz' archive
        curl -L -o /tmp/powershell.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/powershell-7.5.0-linux-arm64.tar.gz 

        # Create the target folder where powershell will be placed
        mkdir -p /opt/microsoft/powershell/7

        # Expand powershell to the target folder
        tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7

        # Set execute permissions
        chmod +x /opt/microsoft/powershell/7/pwsh

        # Create the symbolic link that points to pwsh
        ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
        ;;
    *)
        echo "Unsupported architecture: $arch"
        exit 1
        ;;
esac

# Verify PowerShell installation
if command -v pwsh &> /dev/null; then
    echo "PowerShell successfully installed."
else
    echo "PowerShell installation failed."
fi