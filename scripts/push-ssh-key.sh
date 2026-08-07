#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
source .env
set +a

JUMP="macos@100.126.151.59"
KEY="$HOME/.ssh/ansible.pub"

python3 inventory/orchard_inv.py |
  python3 -c 'import json,sys; [print(v["ansible_host"]) for v in json.load(sys.stdin)["_meta"]["hostvars"].values()]' |
  while read -r ip; do
    echo ">> admin@$ip"
    ssh-copy-id -f -i "$KEY" \
      -o ProxyJump="$JUMP" \
      -o StrictHostKeyChecking=accept-new \
      "admin@$ip"
  done
