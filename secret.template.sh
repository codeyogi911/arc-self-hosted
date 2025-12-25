#!/bin/bash
# GitHub App Secret Configuration
# Copy this file to secret.sh and fill in your values
# NEVER commit secret.sh to version control!

kubectl create secret generic pre-defined-secret \
   --namespace=arc-runners \
   --from-literal=github_app_id=YOUR_APP_ID \
   --from-literal=github_app_installation_id=YOUR_INSTALLATION_ID \
   --from-literal=github_app_private_key='-----BEGIN RSA PRIVATE KEY-----
YOUR_PRIVATE_KEY_HERE
-----END RSA PRIVATE KEY-----
'

