# Security policy

## Supported code

Security fixes are made on the current default branch and the latest immutable
release. Older releases may be asked to upgrade when a fix depends on kernel or
installer changes.

The module runs in the Linux kernel. Treat crashes, memory corruption, stale
cross-namespace state, capability bypasses, and release identity failures as
security issues even when they require unusual traffic or teardown timing.

## Reporting a vulnerability

Use the repository's private GitHub security-advisory form at
`https://github.com/sagehere/TCP-Brutal-Custom/security/advisories/new`. Include
the affected commit or release, kernel version and architecture, configuration,
reproduction steps, and relevant kernel logs. Do not include secrets or public
exploit details in an issue before a fix is available.

## Security boundaries

- Generic Netlink rule and limit mutations require `CAP_NET_ADMIN` in the
  target network namespace. Reads and dumps expose only that namespace.
- Procfs rules, limits, statistics, and peer views are per-network-namespace.
- Per-IP grouping is traffic accounting, not authentication. Clients behind
  one NAT share an identity, while one client may appear under several IPv4 or
  IPv6 addresses.
- `hashed_fallback` preserves service when peer allocation or budgets fail. It
  is not strict tenant isolation and collisions may share a fallback pacer.
- The manager and DKMS installer require root because they install kernel code,
  routes, systemd units, and traffic-control state.

The detailed trust and failure analysis is in
[`docs/threat-model.md`](docs/threat-model.md). No external security or kernel
audit is claimed unless a report identifying the reviewer and reviewed commit
is linked from the repository.

## Release verification

Official installation consumes an immutable GitHub Release. The installer
checks release metadata, GitHub asset digests, `SHA256SUMS`, the release
manifest, and the source archive identity before DKMS builds. When supported by
the installed GitHub CLI it also verifies release and asset attestations. A
source build outside that chain reports an all-zero build ID unless the builder
supplies a verified commit.
