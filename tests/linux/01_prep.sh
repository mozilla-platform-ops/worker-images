echo "Installing PowerShell..."
#snap install powershell --classic

# Update the list of packages
apt-get update

# Install pre-requisite packages.
apt-get install -y wget apt-transport-https software-properties-common

# Get the version of Ubuntu
source /etc/os-release

# Download the Microsoft repository keys
wget -q https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/p/powershell-preview/powershell-preview_7.5.0-preview.5-1.deb_amd64.deb

# Register the Microsoft repository keys
dpkg -i powershell-preview_7.5.0-preview.5-1.deb_amd64.deb

# Delete the Microsoft repository keys file
rm powershell-preview_7.5.0-preview.5-1.deb_amd64.deb

# Update the list of packages after we added packages.microsoft.com
apt-get update

###################################
# Install PowerShell
apt-get install -y powershell

# Verify PowerShell installation
if command -v pwsh &> /dev/null
then
    echo "PowerShell successfully installed."
else
    echo "PowerShell installation failed."
fi