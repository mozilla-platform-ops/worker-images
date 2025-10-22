#!/bin/bash

# Check if use_keyvault environment variable is set to true
if [[ "${use_keyvault}" == "true" ]]; then
    # Write the cotkey content to the ed25519_key file
    echo "${cotkey}" > /etc/generic-worker/ed25519_key

    # Set appropriate permissions for the key file
    chmod 600 /etc/generic-worker/ed25519_key
    
    echo "use_keyvault is true, wrote COT key to /etc/generic-worker/ed25519_key"
else
    echo "use_keyvault is not set to true, no action taken"
fi