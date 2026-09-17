# Threat model

## Assets and trust boundaries

The protected assets are kernel memory safety and liveness, namespace
isolation, configured pacing policy, peer-resource availability, and the
identity of installed kernel source. Remote peers are untrusted. Processes
with `CAP_NET_ADMIN` in a network namespace are trusted to configure that
namespace but not another one. Host root and the release publisher are fully
trusted and can replace kernel code.

## Remote traffic

An attacker can open and close connections rapidly, coordinate same-address
reconnects, rotate IPv6 addresses, vary IPv4-mapped IPv6 forms, and force hash
collisions. Peer slots are reserved before allocation, observable counts are
separate from reservations, duplicate and failure paths release their slots,
and peer destruction uses refcounts, a lifecycle lock, rhashtable removal, and
RCU reclamation. Namespace and per-rule limits bound live peer objects.

When a limit, allocation, or insertion fails, traffic uses a fixed fallback
pacer and increments failure/fallback counters. This favors availability. It
does not guarantee that mutually hostile clients retain separate rates under
pressure because fallback hashes can collide.

Per-IP policy cannot identify a person or tenant. CGNAT causes unrelated users
to share a rate. Address rotation can obtain multiple per-IP budgets unless a
higher-level policy prevents it. Dual-stack clients can receive separate IPv4
and IPv6 groups. Operators requiring identity-based quotas must enforce them at
an authenticated application or gateway layer.

## Local processes and namespaces

Unprivileged sockets may select an allowed congestion-control algorithm and
generate traffic, but cannot mutate rules or limits. Generic Netlink checks
`CAP_NET_ADMIN` against the caller's target namespace; proc entries use the
same namespace capability boundary. Reads reveal peer addresses and traffic
counters within that namespace, so container policy should restrict proc and
Netlink observation when this metadata is sensitive.

User-created network namespaces receive independent mutable tables and
counters. No module-wide mutable rule or peer table is used. Teardown must
remove proc entries, stop dumps, unlink hashes and XArray entries, wait for RCU,
and release all group and peer references.

## Operator mistakes

Root can configure excessive rates, very broad prefixes, large unlimited peer
budgets, or overlapping route and `tc` policies. Longest-prefix lookup makes
overrides deterministic, but cannot make an unsafe rate suitable for a path.
The manager-level `tc` aggregate and kernel rule aggregate have different
scope; enabling both is valid but the lower effective bottleneck wins.

Rule changes affect new matches and live group configuration as documented.
Deleting a rule does not rewrite already established sockets. Operational
events are best-effort observation and must not be the sole source of desired
configuration state.

## Supply chain

The primary risks are a mutable or substituted release, mismatched source and
manifest, compromised publisher credentials, malicious build dependencies,
and a stale DKMS build loaded after upgrade. Release assets bind tag, version,
and full commit; installation checks immutable release metadata, digests,
checksums, manifest fields, source identity, and the installed commit marker.
These checks do not protect against compromise of the source repository,
publisher account, GitHub infrastructure, local root, compiler, or kernel.

## Failure behavior

- Rule index insertion rolls back earlier index changes before publication.
- Stale active-prefix bits can cause a harmless hash miss, not a freed-rule
  dereference.
- Rule IDs stop with `ENOSPC` rather than wrapping onto a live ID.
- Peer pressure degrades to hashed fallback instead of rejecting an already
  created TCP socket.
- Netlink messages are typed and length-checked; large dumps are multipart.
- Parent/child pacing uses one documented lock order to avoid inversion.

Kernel warnings, stalls, refcount failures, RCU reports, and unexplained peer
slot leakage are release blockers.

## Review scope and residual risk

An external kernel review should concentrate on peer refcounts and RCU,
rule lifetime and netns teardown, XArray/rhashtable publication, slot
accounting, parent/child reservation settlement, Netlink parsing and dump
lifetimes, fault injection, and unload races. No external audit has been
performed or claimed for the current P2 code.
