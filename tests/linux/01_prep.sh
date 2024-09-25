echo "Installing PowerShell..."
snap install powershell --classic

# Verify PowerShell installation
if command -v pwsh &> /dev/null
then
    echo "PowerShell successfully installed."
else
    echo "PowerShell installation failed."
fi