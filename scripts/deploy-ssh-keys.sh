#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Deploy Ansible SSH Public Key to Linux VMs in Nautobot
#
# Features:
#   - Queries Nautobot API
#   - Identifies Linux VMs by platform
#   - Uses primary IPv4 addresses
#   - Skips VMs without primary IP addresses
#   - Prevents duplicate IP processing
#   - Loads SSH private key into ssh-agent once
#   - Uses ssh-copy-id to deploy the public key
#   - Continues if an individual server fails
#
# Safety:
#   - Dry-run by default
#   - Never copies the private key
#   - SSH host key verification remains enabled
#   - Does not modify Nautobot
#
# Usage:
#   ./deploy-ssh-keys.sh
#   ./deploy-ssh-keys.sh --apply
# ============================================================

NAUTOBOT_URL="${NAUTOBOT_URL:-}"
NAUTOBOT_TOKEN="${NAUTOBOT_TOKEN:-}"

SSH_USER="asnyder"

PRIVATE_KEY="${HOME}/.ssh/ansible_ed25519"
PUBLIC_KEY="${PRIVATE_KEY}.pub"

MODE="${1:---dry-run}"

if [[ "$MODE" != "--dry-run" && "$MODE" != "--apply" ]]; then
    echo "Usage: $0 [--dry-run|--apply]"
    exit 1
fi

# ------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------

if [[ -z "$NAUTOBOT_URL" || -z "$NAUTOBOT_TOKEN" ]]; then
    echo "ERROR: NAUTOBOT_URL and NAUTOBOT_TOKEN must be set."
    exit 1
fi

if [[ ! -f "$PRIVATE_KEY" ]]; then
    echo "ERROR: Private key not found: $PRIVATE_KEY"
    exit 1
fi

if [[ ! -f "$PUBLIC_KEY" ]]; then
    echo "ERROR: Public key not found: $PUBLIC_KEY"
    exit 1
fi

NAUTOBOT_URL="${NAUTOBOT_URL%/}"

TEMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

HOST_FILE="${TEMP_DIR}/hosts.tsv"

echo "=================================================="
echo " Nautobot Linux SSH Key Deployment"
echo "=================================================="
echo
echo "Nautobot:  $NAUTOBOT_URL"
echo "SSH User:  $SSH_USER"
echo "Public Key: $PUBLIC_KEY"
echo "Mode:      $MODE"
echo

# ------------------------------------------------------------
# Retrieve Linux VMs from Nautobot
#
# Python standard library is used for API access.
# No additional Python packages are required.
# ------------------------------------------------------------

echo "Retrieving VM inventory from Nautobot..."

python3 - "$HOST_FILE" <<'PYTHON'
import ipaddress
import json
import os
import re
import sys
import urllib.request

output_file = sys.argv[1]

base_url = os.environ["NAUTOBOT_URL"].rstrip("/")
token = os.environ["NAUTOBOT_TOKEN"]

headers = {
    "Authorization": f"Token {token}",
    "Accept": "application/json",
}

def api_get(path):
    url = f"{base_url}{path}"

    request = urllib.request.Request(
        url,
        headers=headers,
    )

    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def get_all(path):
    results = []

    while path:
        data = api_get(path)
        results.extend(data["results"])

        next_url = data.get("next")

        if not next_url:
            break

        if next_url.startswith(base_url):
            path = next_url[len(base_url):]
        else:
            raise RuntimeError(
                f"Unexpected Nautobot pagination URL: {next_url}"
            )

    return results


# ------------------------------------------------------------
# Retrieve platforms
# ------------------------------------------------------------

platforms = get_all("/api/dcim/platforms/?limit=1000")

linux_pattern = re.compile(
    r"linux|ubuntu|debian|rocky|alma|centos|fedora|"
    r"rhel|red hat|suse|oracle linux",
    re.IGNORECASE,
)

linux_platform_ids = {
    str(platform["id"])
    for platform in platforms
    if linux_pattern.search(platform["name"])
}

# ------------------------------------------------------------
# Retrieve virtual machines
# ------------------------------------------------------------

vms = get_all(
    "/api/virtualization/virtual-machines/?limit=1000"
)

selected = []
skipped_no_ip = []
seen_ips = set()

for vm in vms:

    name = vm["name"]

    platform = vm.get("platform")

    if not platform:
        continue

    platform_id = str(platform.get("id", ""))

    if platform_id not in linux_platform_ids:
        continue

    # --------------------------------------------------------
    # Retrieve the primary IPv4 address
    # --------------------------------------------------------

    primary_ip = vm.get("primary_ip4")

    if not primary_ip:
        skipped_no_ip.append(name)
        continue

    # Nautobot may return either an address or an ID
    address = primary_ip.get("address")

    if not address:
        ip_id = primary_ip.get("id")

        if not ip_id:
            skipped_no_ip.append(name)
            continue

        ip_record = api_get(
            f"/api/ipam/ip-addresses/{ip_id}/"
        )

        address = ip_record.get("address")

    if not address:
        skipped_no_ip.append(name)
        continue

    # Remove CIDR suffix
    ip = address.split("/")[0]

    try:
        parsed_ip = ipaddress.ip_address(ip)

        if (
            parsed_ip.version != 4
            or parsed_ip.is_loopback
            or parsed_ip.is_link_local
            or parsed_ip.is_multicast
            or parsed_ip.is_unspecified
        ):
            continue

    except ValueError:
        continue

    if ip in seen_ips:
        print(
            f"WARNING: Duplicate management IP {ip} "
            f"found for {name}; skipping duplicate.",
            file=sys.stderr,
        )
        continue

    seen_ips.add(ip)

    selected.append((name, ip))


selected.sort(key=lambda x: x[0].lower())

# ------------------------------------------------------------
# Write host list
# ------------------------------------------------------------

with open(output_file, "w", encoding="utf-8") as f:
    for name, ip in selected:
        f.write(f"{name}\t{ip}\n")


print()
print("Linux VMs with primary IPv4 addresses:")
print()

for name, ip in selected:
    print(f"  {name:<35} {ip}")

print()
print(f"Eligible Linux VMs: {len(selected)}")
print(f"Linux VMs missing primary IP: {len(skipped_no_ip)}")

if skipped_no_ip:
    print()
    print("Skipped (no primary IPv4):")

    for name in sorted(skipped_no_ip):
        print(f"  {name}")

PYTHON

# ------------------------------------------------------------
# Stop if there are no eligible hosts
# ------------------------------------------------------------

HOST_COUNT="$(wc -l < "$HOST_FILE")"

if [[ "$HOST_COUNT" -eq 0 ]]; then
    echo
    echo "No eligible Linux VMs found."
    exit 0
fi

# ------------------------------------------------------------
# Dry run
# ------------------------------------------------------------

if [[ "$MODE" == "--dry-run" ]]; then
    echo
    echo "Dry-run complete. No SSH connections were made."
    echo
    echo "Run with --apply to install the public key."
    exit 0
fi

# ------------------------------------------------------------
# Confirm deployment
# ------------------------------------------------------------

echo
read -r -p \
    "Deploy SSH public key to these ${HOST_COUNT} hosts? [y/N]: " \
    CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# ------------------------------------------------------------
# Load private key into ssh-agent
#
# If the key has a passphrase, ssh-add prompts once.
# ------------------------------------------------------------

if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    eval "$(ssh-agent -s)" >/dev/null
    STARTED_AGENT=true
else
    STARTED_AGENT=false
fi

echo
echo "Loading Ansible private key into ssh-agent..."
echo "Enter the private key passphrase if prompted."
echo

ssh-add "$PRIVATE_KEY"

# ------------------------------------------------------------
# Deploy public key
# ------------------------------------------------------------

SUCCESS=0
FAILED=0

echo
echo "Beginning SSH public key deployment..."
echo

while IFS=$'\t' read -r HOSTNAME IP; do

    echo "--------------------------------------------------"
    echo "Host: $HOSTNAME"
    echo "IP:   $IP"
    echo "--------------------------------------------------"

    if ssh-copy-id \
        -i "$PUBLIC_KEY" \
        -o StrictHostKeyChecking=ask \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${IP}"
    then
        echo "SUCCESS: $HOSTNAME ($IP)"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "FAILED: $HOSTNAME ($IP)"
        FAILED=$((FAILED + 1))
    fi

    echo

done < "$HOST_FILE"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "=================================================="
echo " SSH Key Deployment Summary"
echo "=================================================="
echo
echo "Total hosts: $HOST_COUNT"
echo "Successful:  $SUCCESS"
echo "Failed:      $FAILED"
echo

# ------------------------------------------------------------
# Clean up agent only if started by this script
# ------------------------------------------------------------

if [[ "$STARTED_AGENT" == true ]]; then
    ssh-agent -k >/dev/null
fi

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi

echo "Deployment complete."
