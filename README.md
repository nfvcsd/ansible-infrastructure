# Ansible Infrastructure Automation

Ansible automation for discovering, documenting, synchronizing, and managing virtual infrastructure using Microsoft Hyper-V and Nautobot.

This repository integrates:

- **Nautobot** — Infrastructure source of truth
- **Microsoft Hyper-V** — Virtual machine hosting
- **Ansible** — Infrastructure discovery and configuration management
- **WinRM** — Hyper-V host administration
- **SSH** — Linux guest administration
- **Git** — Version control and change tracking

## 1. Overview

This project provides automated workflows for:

- Discovering virtual machines across multiple Hyper-V hosts
- Synchronizing virtual machine information with Nautobot
- Reconciling VM identities using Hyper-V GUIDs
- Discovering and classifying guest operating systems
- Enabling Hyper-V integration services
- Installing and configuring Linux Hyper-V guest utilities
- Managing SSH public-key deployment
- Auditing infrastructure configuration without making changes

Most synchronization and configuration playbooks support a read-only mode by default. Infrastructure changes require explicitly enabling the appropriate configuration flags.

## 2. Repository Structure

```text
ansible/
├── ansible.cfg
├── inventory/
│   ├── nautobot.yml
│   ├── hyperv-hosts.yml
│   ├── group_vars/
│   └── host_vars/
├── playbooks/
│   ├── collect-facts.yml
│   ├── discover-hyperv-all.yml
│   ├── sync-vm-software-versions.yml
│   ├── sync-hyperv-all.yml
│   ├── reconcile-nautobot.yml
│   ├── reconcile-vm-platforms.yml
│   ├── discover-vm-operating-systems.yml
│   ├── discover-unclassified-vms.yml
│   ├── configure-linux-hyperv-integrations.yml
│   ├── enable-hyperv-integrations-complete.yml
│   └── create-missing-hyperv-vms.yml
├── scripts/
│   └── deploy-ssh-keys.sh
└── README.md
```

Some older playbooks may remain in the repository for compatibility or reference. Review their behavior before executing them.

## 3. Requirements

### Ansible Controller

- Linux-based Ansible controller
- Python 3
- Ansible Core
- Required Ansible collections
- Network connectivity to Hyper-V hosts and managed Linux guests
- Nautobot API access

### Hyper-V Hosts

- Microsoft Hyper-V
- WinRM configured for Ansible connectivity
- Appropriate administrative permissions
- PowerShell Hyper-V module available

### Linux Guests

- SSH connectivity
- Compatible Python interpreter for Ansible modules
- Authorized SSH public key or other approved authentication
- Sudo privileges for package and service management

The Hyper-V guest utility installation workflow currently supports Ubuntu Linux.

### Nautobot

The following information is used by the automation:

| Field | Purpose |
|---|---|
| VM name | Human-readable identity |
| Cluster | Virtualization infrastructure association |
| Platform | Operating system classification |
| Primary IP | Guest management connectivity |
| Hyper-V GUID custom field | Matches Nautobot records to Hyper-V VMs |

The custom field used for Hyper-V identity is:

```text
hyper_v_vm_id
```

This enables reliable VM matching even when different clusters contain VMs with identical names.

## 4. Playbook Reference

### `collect-facts.yml`

**Purpose:** Collect system information from Ansible-managed infrastructure.

Typical collected information includes:

- Operating system and version
- CPU and memory
- Hostname
- Network interfaces
- IP addresses
- System hardware information

The collected facts can support infrastructure documentation, reconciliation, and configuration management.

**Requirements:** Ansible connectivity and a compatible remote Python interpreter.

**Changes:** Review the installed playbook before execution to determine whether it writes inventory information.

### `discover-hyperv-all.yml`

**Purpose:** Discover virtual machines across all configured Hyper-V hosts.

The playbook connects to Hyper-V hosts and collects:

- VM name
- VM GUID
- Hyper-V host
- Power state
- Virtual processor count
- Configured memory
- Total provisioned virtual disk capacity

It consolidates discovery results and checks for duplicate GUIDs.

This playbook is also imported by other workflows that require authoritative Hyper-V VM information.

**Mode:** Read-only.

**Run:**

```bash
ansible-playbook playbooks/discover-hyperv-all.yml
```

### `sync-hyperv-all.yml`

**Purpose:** Synchronize Hyper-V virtual machine information with Nautobot.

The playbook reconciles:

- VM identity
- Hyper-V GUID
- Virtual CPU allocation
- Memory allocation
- Total provisioned virtual disk capacity
- Cluster association
- Missing VM records

Existing records are matched using available identity information, prioritizing Hyper-V GUIDs.

New Nautobot VM records can be created when explicitly enabled.

#### Configuration flags

| Variable | Default | Function |
|---|---|---|
| `nautobot_sync_enabled` | `false` | Update existing VM records |
| `nautobot_cluster_sync_enabled` | `false` | Synchronize cluster information |
| `nautobot_create_enabled` | `false` | Create missing VM records |

**Read-only audit:**

```bash
ansible-playbook playbooks/sync-hyperv-all.yml
```

**Synchronize existing records:**

```bash
ansible-playbook playbooks/sync-hyperv-all.yml \
  -e nautobot_sync_enabled=true
```

Review proposed changes before enabling cluster synchronization or VM creation.

Existing records should preserve unrelated fields such as status, platform, primary IP, interfaces, and tags.

Disk synchronization uses Nautobot's `disk` field. It sums the provisioned `Size`
of all attached virtual disks, divides by 2^30 bytes (PowerShell's `1GB`), and
rounds the total upward to a whole number. This measures allocated guest disk
capacity, not filesystem free space or the VHD file's current storage consumption.
Checkpoint parent disks are not counted separately. A VM with no attached disks
has a capacity of zero.

Disk changes use `nautobot_sync_enabled`, and newly created records include disk
capacity when available. If any disk cannot be inspected, or a pass-through disk
is present, the entire VM's disk capacity is reported as unavailable: existing
values are preserved, and new records omit the disk field. Other fields can still
sync. Use `-e nautobot_sync_enabled=true --check` to preview proposed disk updates
without writing them; the default audit leaves update proposals gated by the sync
flags.

References: [Nautobot VM fields](https://docs.nautobot.com/projects/ansible/en/latest/networktocode.nautobot/module/virtual_machine.html)
and [Microsoft Get-VHD](https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vhd).


### `reconcile-nautobot.yml`

**Purpose:** Perform Nautobot inventory reconciliation.

This is an earlier reconciliation workflow that includes Nautobot update operations.

**Recommendation:** Prefer `sync-hyperv-all.yml` for normal Hyper-V inventory synchronization.

Review this playbook's write behavior before running it.

### `reconcile-vm-platforms.yml`

**Purpose:** Audit VM platform assignments and identity information.

The playbook identifies:

- VMs without operating-system platforms
- Missing Hyper-V GUID information
- VM identity conflicts
- Nautobot records not discovered on Hyper-V
- Linux VMs eligible for integration management

It resolves platform names using Nautobot platform IDs and compares VM records with Hyper-V discovery results.

**Mode:** Read-only.

```bash
ansible-playbook playbooks/reconcile-vm-platforms.yml
```

This is useful after adding, migrating, or retiring VMs.

### `sync-vm-software-versions.yml`

**Purpose:** Discover Linux and Windows guest OS releases and assign Nautobot
Software Version records. Requires Nautobot 2.2 or later.

The `nautobot_vm_guests` inventory group selects all virtual machines independently
of their role or platform. Linux guests require working SSH credentials and a
compatible Python interpreter. Windows guests require `ansible_connection: winrm`
or `psrp`, appropriate credentials, and guest connectivity. Windows over SSH is
not supported by this workflow. Configure guest credentials through inventory or
private variables; Hyper-V host credentials do not automatically grant guest access.

Linux records follow Nautobot's native platform/software-version model:

| Field | Ubuntu example | Red Hat example |
|---|---|---|
| Platform | Ubuntu | RHEL |
| Version | 24.04 | Detected numbered release |
| Alias | noble | Detected release codename, if available |
| OS family in report | Linux | Linux |

The platform is the distribution without a version suffix. `RedHat` and
`Red Hat Enterprise Linux` normalize to `RHEL`; other distribution names are
retained. Version comes from `ansible_distribution_version` and alias from
`ansible_distribution_release` (for example, `jammy` or `noble`). Point-release
numbers are retained as reported by the guest. Codenames are discovered, not
inferred from a hardcoded version table. Missing/unknown codenames leave new
aliases blank and preserve existing aliases.

Apply mode updates an existing Linux Software Version alias if a detected codename
differs, including when the VM already references that version. This is a shared
record: its alias changes for all VMs referencing it. Audit reports these changes
as `WOULD_UPDATE_ALIAS`.

Linux remains an OS family in reports and in the existing platform-based Linux
inventory selection; this workflow does not create an OS-family custom field or
tag. Separate distribution platforms prevent equal version numbers from different
distributions sharing a Software Version record.

Windows records
use the OS version/build reported by `Win32_OperatingSystem` (for example,
`10.0.20348`), with its product caption as the software version alias. This does not
inventory applications, Linux kernel versions, or Windows cumulative-update revisions.

Records are matched by unique, exact Nautobot VM name and inventory hostname.
Unreachable guests, ambiguous names, and VMs without platforms are reported and
skipped. Linux platform names must match the normalized distribution (or its
explicit `nautobot_os_platform_names` mapping), ignoring case. A legacy platform
such as `Ubuntu 24.04` or a generic `Linux` platform is reported for migration to
`Ubuntu`, requiring the platform creation/replacement flags below. Windows retains
its existing matching behavior: a platform containing `Windows` or an explicit
mapping is accepted.
Unclassified or mismatched VMs are reported by default. Optional platform onboarding
is described below.
VMs absent from guest inventory are reported separately.

**Audit (default):**

```bash
ansible-playbook playbooks/sync-vm-software-versions.yml
```

**Check-mode preview:**

```bash
ansible-playbook playbooks/sync-vm-software-versions.yml \
  -e nautobot_software_sync_enabled=true --check
```

**Create missing software versions and assign verified VM releases:**

```bash
ansible-playbook playbooks/sync-vm-software-versions.yml \
  -e nautobot_software_sync_enabled=true
```

Existing software versions are reused by platform and exact version. Apply mode
updates outdated VM assignments and creates missing versions with the `Active`
status. This status must be enabled for Nautobot Software Versions; override its
name using `nautobot_software_version_status` if necessary. Existing VM platforms
and other fields are preserved unless platform onboarding is explicitly enabled. The playbook rechecks VM identity, platform, and
current assignment before writing. Run a single sync at a time to avoid competing
version creation requests. API errors stop reconciliation; already completed
assignments remain in place and can be audited by rerunning.

#### Optional OS platform creation and correction

Missing Software Version records are already created with
`nautobot_software_sync_enabled=true`. To also create and assign missing OS
**Platforms**, enable `nautobot_os_platform_create_enabled=true`.
Existing mismatched platforms are preserved unless you additionally enable
`nautobot_os_platform_replace_enabled=true`.

Preview platform creation and correction, including the detected OS and current
platform:

```bash
ansible-playbook playbooks/sync-vm-software-versions.yml \
  -e nautobot_os_platform_create_enabled=true \
  -e nautobot_os_platform_replace_enabled=true
```

To apply the reviewed proposals, add `-e nautobot_software_sync_enabled=true`.
`--check` always prevents writes, even when all flags are enabled.

New platform names default to the normalized Linux distribution name or Windows product
caption with the leading `Microsoft ` removed. Version numbers are stored in
Software Version records. To reuse your own platform naming convention, pass a
private YAML variables file with an explicit mapping, for example:

```yaml
nautobot_os_platform_names:
  Ubuntu: Ubuntu Linux
  Microsoft Windows Server 2019 Standard: Windows Server 2019
```

An explicit mapping also approves that platform name for the detected distribution.
Use distinct platform names for different distributions; mapping all distributions
to `Linux` would reintroduce version-number collisions.
Platforms created earlier in the run are reused. Replacement clears the old software
version before assigning a version for the new platform; if a later API operation
fails, rerun after resolving it. API writes are not transactional. Unreachable or
unidentified guests never trigger platform creation. Unresolved platform IDs remain
skipped rather than being automatically replaced.

#### Windows OS discovery and Kerberos

OS discovery runs only after guest authentication succeeds. A `Server not found in
Kerberos database` error indicates that Kerberos cannot resolve the requested server
principal. Check the target FQDN, DNS and AD service principal registration. An IP
address or unsuitable short name can cause this failure. The repository's Windows
settings use manual Kerberos tickets, so run `klist` on the controller to verify the
current ticket as well.

For a guest reached by IP, configure its verified AD hostname in private host variables:

```yaml
ansible_winrm_kerberos_hostname_override: windows-vm.example.com
```

For guests whose inventory names match their AD computer names, an optional suffix
sets the Kerberos hostname while retaining the connection address:

```bash
ansible-playbook playbooks/sync-vm-software-versions.yml \
  -e vm_windows_dns_suffix=example.com
```

Use the actual DNS suffix for those computers. This option applies to WinRM and
preserves explicit per-host overrides; it does not fix missing SPNs, DNS entries,
expired tickets, firewalls or WinRM timeouts. For PSRP, configure
`ansible_psrp_negotiate_hostname_override` per host. Verify Windows VMs have
`ansible_connection: winrm` or `psrp`; guests falling back to SSH need their
inventory connection settings corrected.

The report includes the connection type, target address and discovery failure
reason, plus detected OS and existing platform for mismatches. No passwords or
API tokens are intentionally included.
See [Ansible Kerberos troubleshooting](https://docs.ansible.com/projects/ansible-core/2.17/os_guide/windows_winrm.html#troubleshooting-kerberos).

The VM query currently supports up to 1,000 records and stops if additional pages
exist. Audit mode reports proposals without creating records or changing guests.
See [Nautobot software versions](https://docs.nautobot.com/projects/core/en/stable/user-guide/feature-guides/software-image-files-and-versions/).

### `discover-vm-operating-systems.yml`

**Purpose:** Identify the operating systems of Linux hosts accessible through Ansible.

The playbook uses SSH and Ansible facts to collect:

- Distribution name
- Distribution version
- Operating-system information

It compares those results with Nautobot VM records and Hyper-V GUIDs.

Supported operating systems can be mapped to existing Nautobot platforms.

Existing platform assignments are preserved.

**Read-only audit:**

```bash
ansible-playbook playbooks/discover-vm-operating-systems.yml
```

**Apply verified platform assignments:**

```bash
ansible-playbook playbooks/discover-vm-operating-systems.yml \
  -e nautobot_platform_sync_enabled=true
```

The operating-system mappings must match existing Nautobot platform names.
Ubuntu 20.04, 22.04, and 24.04 all map to the `Ubuntu` platform; release numbers
and codenames are handled by `sync-vm-software-versions.yml`.

### `discover-unclassified-vms.yml`

**Purpose:** Discover operating systems for VMs that do not have platforms assigned in Nautobot.

This playbook:

1. Retrieves Hyper-V inventory.
2. Identifies unclassified Nautobot VM records.
3. Matches VMs using their Hyper-V GUIDs.
4. Checks an approved candidate list.
5. Retrieves available management IP addresses.
6. Optionally identifies operating systems through SSH.
7. Proposes Nautobot platform assignments.

SSH discovery uses `/etc/os-release` and does not require a compatible remote Python interpreter.

**Inventory audit:**

```bash
ansible-playbook playbooks/discover-unclassified-vms.yml
```

**Enable guest discovery:**

```bash
ansible-playbook playbooks/discover-unclassified-vms.yml \
  -e vm_discovery_probe_enabled=true
```

**Apply verified platform assignments:**

```bash
ansible-playbook playbooks/discover-unclassified-vms.yml \
  -e vm_discovery_probe_enabled=true \
  -e nautobot_platform_sync_enabled=true
```

**Limitations:** Guest probing requires an approved candidate and a reachable management IP address.
The default Ubuntu release mappings target the existing `Ubuntu` platform.
This workflow assigns missing platforms; use `sync-vm-software-versions.yml`
to assign numbered software versions and release aliases.

### `configure-linux-hyperv-integrations.yml`

**Purpose:** Enable integration services for Linux virtual machines directly through Hyper-V.

The playbook identifies Linux VMs using:

- Nautobot platform information
- Hyper-V GUID custom field
- Hyper-V discovery results

It configures the integration services through the Hyper-V host without requiring SSH connectivity to the guest.

#### Managed integration services

| Service | Function |
|---|---|
| Heartbeat | Guest health reporting |
| Key-Value Pair Exchange | Guest information and IP reporting |
| Shutdown | Graceful guest shutdown |
| Time Synchronization | Host-to-guest time synchronization |
| VSS | Backup integration |
| Guest Service Interface | Host-to-guest file copy support |

**Audit:**

```bash
ansible-playbook playbooks/configure-linux-hyperv-integrations.yml
```

**Apply:**

```bash
ansible-playbook playbooks/configure-linux-hyperv-integrations.yml \
  -e hyperv_integrations_apply=true
```

This playbook does not install packages inside Linux guests.

### `enable-hyperv-integrations-complete.yml`

**Purpose:** Configure Hyper-V host-side integrations and Linux guest-side utilities.

This is the primary playbook for complete Linux Hyper-V integration management.

It imports:

```text
configure-linux-hyperv-integrations.yml
```

It then configures Ubuntu guests through SSH.

#### Guest configuration

The playbook:

1. Detects the operating system and running kernel.
2. Identifies required kernel-specific packages.
3. Installs the appropriate Linux cloud tools.
4. Installs Linux tools and tracking packages.
5. Checks the Hyper-V KVP device.
6. Verifies systemd device registration.
7. Repairs udev registration when necessary.
8. Enables and starts the KVP daemon.
9. Verifies the service state.

#### Kernel-specific packages

Certain Ubuntu kernels require matching cloud tools:

```bash
sudo apt install \
  linux-cloud-tools-$(uname -r) \
  linux-tools-$(uname -r)
```

The playbook detects the running kernel and constructs the appropriate package names automatically.

#### KVP device registration

On some systems, `/dev/vmbus/hv_kvp` exists but systemd does not recognize the corresponding device unit as active.

The playbook includes a conditional recovery procedure equivalent to:

```bash
sudo udevadm control --reload-rules

sudo udevadm trigger --action=add \
  /sys/devices/virtual/misc/vmbus\!hv_kvp

sudo udevadm settle
```

Recovery is intended to occur only when necessary.

#### Execution

**Read-only audit:**

```bash
ansible-playbook \
  playbooks/enable-hyperv-integrations-complete.yml
```

**Apply:**

```bash
ansible-playbook \
  playbooks/enable-hyperv-integrations-complete.yml \
  -e hyperv_integrations_apply=true
```

If sudo requires an interactive password, append `-K`.

The guest stage targets the platform-based `hyperv_linux_guests` inventory group.

#### Excluding devices

Edit `playbooks/vars/hyperv-integrations.yml` to skip selected VMs:

```yaml
hyperv_integrations_excluded_devices:
  - example-vm-01
  - example-vm-02
```

The list defaults to empty and applies in both audit and apply modes. Excluded
VMs are removed from host-side integration selection, and excluded guests are
skipped before SSH connections or fact gathering. The standalone
`configure-linux-hyperv-integrations.yml` playbook also uses this list.

Names match exactly, ignoring case; wildcards are not supported. Use each
Nautobot VM name. If its Ansible inventory hostname differs, include that name
as well so both stages exclude it. All VMs sharing an excluded name are skipped.
These are guest VM exclusions, not Hyper-V host exclusions.

You can override the list for one run using a YAML variables file:

```bash
ansible-playbook playbooks/enable-hyperv-integrations-complete.yml \
  -e @/path/to/private-exclusions.yml
```

The override file should contain the same `hyperv_integrations_excluded_devices`
list shown above. An override replaces the saved list. Keep internal device names
in a private variables file when sharing this repository publicly.

The workflow does not explicitly reboot guest machines.

### `create-missing-hyperv-vms.yml`

**Purpose:** Create Nautobot records for newly discovered Hyper-V virtual machines.

The playbook can create records with:

- VM name
- Hyper-V GUID
- Cluster association
- Virtual hardware information
- Initial status
- Discovery tag

Newly created records typically receive the `Staged` status.

This is an older specialized workflow.

**Recommendation:** Use the consolidated `sync-hyperv-all.yml` workflow for routine inventory synchronization.

Review this playbook carefully before enabling creation to avoid duplicate records.

## 5. Helper Scripts

### `scripts/deploy-ssh-keys.sh`

**Purpose:** Deploy an Ansible SSH public key to Linux VMs discovered through Nautobot.

Features include:

- Query Nautobot for VM and platform information
- Identify systems with recognized Linux platforms
- Retrieve primary IPv4 addresses
- Skip records without usable management addresses
- Avoid duplicate IP processing
- Load an SSH private key into `ssh-agent`
- Prompt once for the private key passphrase
- Use `ssh-copy-id` to install the public key
- Report deployment results

**Dry run:**

```bash
./scripts/deploy-ssh-keys.sh
```

**Apply:**

```bash
./scripts/deploy-ssh-keys.sh --apply
```

The private key remains on the Ansible controller.

Remote account passwords may still be required during initial SSH key deployment.

Host key verification should remain enabled.

## 6. Environment Configuration

### Python virtual environment

Activate the project's Python environment before running Ansible:

```bash
source .venv/bin/activate
```

### Nautobot credentials

The playbooks use two environment variables:

```bash
NAUTOBOT_URL
NAUTOBOT_TOKEN
```

Example configuration:

```bash
export NAUTOBOT_URL="https://nautobot.example.com"
export NAUTOBOT_TOKEN="REPLACE_WITH_YOUR_TOKEN"
```

Do not commit actual API tokens to Git.

A persistent environment file can be created outside the repository:

```text
~/.nautobot-env
```

Example contents:

```bash
export NAUTOBOT_URL="https://nautobot.example.com"
export NAUTOBOT_TOKEN="REPLACE_WITH_YOUR_TOKEN"
```

Restrict permissions:

```bash
chmod 600 ~/.nautobot-env
```

To load the variables automatically in interactive Bash sessions, add this to `~/.bashrc`:

```bash
if [ -f "$HOME/.nautobot-env" ]; then
    source "$HOME/.nautobot-env"
fi
```

For scheduled execution, explicitly configure credentials through the scheduling environment or a suitable secret-management solution.

### SSH credentials

Use public-key authentication wherever possible.

SSH private keys should not be stored in the repository.

### Hyper-V authentication

Hyper-V discovery and management require appropriate WinRM authentication.

Authentication methods and credentials should be configured outside committed playbooks.

## 7. Nautobot Dynamic Inventory

The Nautobot dynamic inventory plugin provides managed hosts to Ansible.

The project can use platform-based groups to classify Linux guests without requiring every VM to have a generic Linux Server role.

Recommended group:

```text
hyperv_linux_guests
```

Platform-based grouping allows systems with specialized roles, such as application servers or Kubernetes nodes, to participate in Linux guest configuration.

Inspect inventory:

```bash
ansible-inventory --graph
```

Check a specific host:

```bash
ansible-inventory --host <vm-name>
```

Test Linux connectivity:

```bash
ansible hyperv_linux_guests \
  -m ansible.builtin.ping
```

A Linux VM generally requires a recognized platform and usable SSH connection settings to participate in guest configuration.

## 8. Recommended Workflows

### Routine discovery

```bash
ansible-playbook playbooks/discover-hyperv-all.yml
```

```bash
ansible-playbook playbooks/sync-hyperv-all.yml
```

Review proposed changes before enabling Nautobot updates.

### After creating a new VM

1. Run Hyper-V discovery.
2. Reconcile the VM with Nautobot.
3. Verify its Hyper-V GUID.
4. Assign or discover its operating-system platform.
5. Configure its management IP if SSH access is required.
6. Deploy the Ansible SSH public key.
7. Run the Hyper-V integrations audit.
8. Apply the necessary integration configuration.

### Platform reconciliation

```bash
ansible-playbook playbooks/reconcile-vm-platforms.yml
```

### Operating-system discovery

```bash
ansible-playbook playbooks/discover-vm-operating-systems.yml
```

### Complete integration configuration

Audit:

```bash
ansible-playbook \
  playbooks/enable-hyperv-integrations-complete.yml
```

Apply:

```bash
ansible-playbook \
  playbooks/enable-hyperv-integrations-complete.yml \
  -e hyperv_integrations_apply=true
```

### After a kernel update

The guest KVP daemon may require updated kernel-specific cloud tools.

Run the integration audit after kernel changes.

Apply the configuration if packages or services require attention.

## 9. Troubleshooting

### SSH host key verification failed

Verify the remote host's SSH fingerprint through a trusted source and update the appropriate `known_hosts` entry.

Do not disable SSH host key verification globally.

### Ansible requires a newer Python interpreter

Some older Linux distributions include Python versions unsupported by newer Ansible releases.

Select a compatible interpreter for the affected host:

```yaml
ansible_python_interpreter: /usr/bin/python3.11
```

Only configure a path that exists on the target.

Do not replace an operating system's default Python interpreter without assessing the impact on system utilities.

### KVP daemon executable missing

Example:

```text
hv_kvp_daemon not found for kernel
```

Install matching packages:

```bash
sudo apt install \
  linux-cloud-tools-$(uname -r) \
  linux-tools-$(uname -r)
```

### KVP service dependency failure

Example:

```text
Dependency failed for hv-kvp-daemon.service
```

Check the systemd KVP device unit:

```bash
systemctl status \
  'sys-devices-virtual-misc-vmbus\x21hv_kvp.device'
```

If the device exists but is inactive, reprocess the relevant udev rules.

The complete integration playbook includes conditional recovery logic.

### Hyper-V guest IP addresses are missing

Verify the following:

- Hyper-V Key-Value Pair Exchange is enabled.
- The Linux kernel exposes the KVP device.
- The systemd KVP device unit is active.
- The KVP daemon is running.
- The guest network interface has a valid IP address.

Example PowerShell verification:

```powershell
Get-VMNetworkAdapter -VMName "<vm-name>" |
    Select-Object VMName, IPAddresses
```

### Linux VM not included in integration management

Check:

- Nautobot platform
- Hyper-V GUID
- Dynamic inventory grouping
- Management address
- SSH authentication
- Python compatibility
- Sudo access

Also confirm that the installed integration playbook targets the intended Linux inventory group.

## 10. Safety and Change Management

This repository is intended to support controlled infrastructure management.

Recommended practices:

- Run read-only audits before applying changes.
- Use explicit synchronization and configuration flags.
- Validate VM identity using Hyper-V GUIDs.
- Preserve existing Nautobot metadata unless updates are specifically intended.
- Avoid automatically creating duplicate VM records.
- Keep secrets and private keys outside Git.
- Review proposed package changes on production systems.
- Avoid automatic guest reboots.
- Verify both host-side integrations and guest-side service health.
- Review new automation before scheduling unattended execution.

Some Ansible inventory operations may report `changed` even when no infrastructure modification occurred. Always inspect the executed tasks when interpreting playbook results.

## 11. Future Improvements

Potential enhancements include:

- Standardizing platform-based guest inventory selection
- Improved verification of Hyper-V guest IP reporting
- Automated reconciliation reports
- JSON output for monitoring and audit systems
- GitHub Actions validation and linting
- Reusable Ansible roles
- Automated detection of missing guest integration tools
- Scheduled read-only infrastructure health audits

## 12. Maintenance Notes

This documentation describes the intended functions and operating procedures of the repository's playbooks.

Some older workflows may contain overlapping functionality. Their write operations should be reviewed before execution.

Update this README whenever configuration flags, inventory group names, supported operating systems, or synchronization behavior change.

---

## Security Considerations

This README intentionally excludes:

- Internal hostnames and DNS domains
- Private IP addresses and network topology
- Organization-specific identifiers
- Account usernames
- API tokens and passwords
- SSH private keys
- Internal infrastructure paths

All examples use generic values intended for public documentation.

**Before publishing the repository, also inspect Ansible inventory files, group variables, host variables, Git history, and any committed environment files for sensitive data.** Removing secrets from this README does not remove them from other repository files or previous commits.