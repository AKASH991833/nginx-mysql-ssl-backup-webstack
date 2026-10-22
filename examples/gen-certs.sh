#!/usr/bin/env bash
# Generate the self-signed lab certificate (CN=lab.example.test, SAN localhost) into examples/certs/.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs
openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
  -keyout certs/privkey.pem -out certs/fullchain.pem \
  -subj "/CN=lab.example.test" -addext "subjectAltName=DNS:lab.example.test,DNS:localhost"
chmod 600 certs/privkey.pem
echo "wrote certs/{fullchain.pem,privkey.pem} (self-signed, 90 days)"
