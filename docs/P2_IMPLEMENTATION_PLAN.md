# TCP-Brutal-Custom P2 implementation specification

Status: implemented; local WSL runtime validation complete, dedicated-hardware
release evidence pending (see `docs/p2-validation.md`)
Project: `sagehere/TCP-Brutal-Custom`  
P2 baseline: `65df326567df1a38dd2f227922723d1040bbacb9`  
Baseline source version: `2.5.3`

Implementation status:

| Phase | Result |
| --- | --- |
| P2-00 | Baseline gates and dry-run scale entry points are present. |
| P2-01 | Stable vendor/ABI/capability discovery is implemented. |
| P2-02 | Namespace/rule peer budgets and hashed fallback are implemented. |
| P2-03 | Monotonic XArray rule IDs and indexed peer iteration are implemented. |
| P2-04 | Intermediate IPv4/IPv6 CIDRs use the bounded prefix index. |
| P2-05 | Repeatable perf/lock/c2c/sched and memory measurement is present; no speculative layout change was made. |
| P2-06A | Hierarchy reservation state fits the enforced private-state bound. |
| P2-06B | Optional parent/child aggregate pacing is implemented. |
| P2-07 | Typed, namespace-scoped Generic Netlink control, dumps and events are implemented with procfs fallback. |
| P2-08 | Architecture, threat model, security policy and audit scope are documented. |

The implementation status does not claim external audit or final release
acceptance. Local WSL build, runtime, and 8-CPU perf evidence is recorded in
`docs/p2-validation.md`; debug kernels and dedicated-host hardware evidence
must still be attached before release promotion.

## 1. Purpose

P2 evolves TCP-Brutal-Custom toward a maintainable architecture with stable
capability discovery, explicit peer-resource governance, scalable rule/peer
indexes, bounded CIDR lookup, evidence-driven hot-state optimization, optional
hierarchical aggregate pacing, a Generic Netlink machine API, and a documented
security/failure model.

P2 is not permission to rewrite the congestion-control algorithm. Existing
behavior remains the default unless a new feature is explicitly enabled.

## 2. Invariants

### 2.1 Socket ABI

`TCP_BRUTAL_PARAMS` and `TCP_BRUTAL_VERSION` retain their existing numbers and
semantics. Existing 12-byte and 20-byte `brutal_params` callers must continue
to work. New information must use a new option number or another explicit API.

### 2.2 Congestion-control private state

Every change to `struct brutal` must keep:

```c
BUILD_BUG_ON(sizeof(struct brutal) > ICSK_CA_PRIV_SIZE);
```

A PR changing the structure must report its old/new size and the available
private-storage limit in every supported build environment.

### 2.3 Rate semantics

A rule configured as `perip rate=X` continues to give each peer-address group
its own X target when kernel aggregate pacing is disabled. Existing shared
rule and application-group semantics remain unchanged.

### 2.4 Network namespaces

All mutable rules, peers, resource budgets, indexes, statistics, limits and
Generic Netlink operations are scoped to the appropriate `struct net`. No new
module-wide mutable rule/peer/configuration table is permitted.

### 2.5 Existing aggregate egress mechanism

The manager-level `AGGREGATE_RATE` implemented with guarded `tc` egress
filtering remains supported through P2. Future in-kernel aggregate pacing has
rule/group semantics and must not silently replace the interface-oriented `tc`
protection path.

## 3. Global engineering rules

1. One architectural P2 phase per PR.
2. Do not add speculative lock-free/per-CPU/CAS pacing, batch credit, idle-peer
   caching, custom tries or cacheline padding without benchmark evidence.
3. The transmit hot path must not add sleeping locks, `GFP_KERNEL` allocation,
   filesystem access, per-packet Netlink messages or rule-list scans.
4. Keep division outside pacer spinlock critical sections.
5. Hierarchical pacing lock order is always parent aggregate pacer, then child
   peer/fallback pacer. Reverse acquisition is forbidden.
6. Feature PRs do not independently bump release versions; version changes
   belong to release-preparation commits.
7. Prefer the smallest coherent change and preserve unrelated behavior.

## 4. Mandatory regression coverage

Every relevant P2 PR must preserve the existing P1 suite, including namespace
integration, application-group isolation, peer churn, reconnect races,
exact-host scaling, peer pagination, RTT/loss testing, benchmark coverage,
brutalctl safety/route tests, aggregate-egress manager tests, debug-runtime
smoke, module lifecycle stress and peer-allocation fault injection.

Debug validation must continue to cover KASAN, KCSAN, LOCKDEP, failslab, RCU
lifetime, reconnect races, netns teardown and module unload/reload.

## 5. P2-00: freeze baseline and establish P2 gates

Goal: create a reproducible P2 comparison point without changing congestion
control behavior.

Add:

- `docs/P2_IMPLEMENTATION_PLAN.md`
- `docs/p2-baseline.md`
- `tests/p2-regression.sh`
- `tests/p2-rule-scale.sh`
- `tests/p2-peer-scale.sh`
- `tests/p2-peer-dump-scale.sh`

The wrappers must support `P2_DRY_RUN=1`. Normal P2 regression reuses the P1
runtime suite. Scale wrappers collect elapsed time at increasing rule/peer
counts and provide an opt-in `P2_EXTREME=1` point.

Definition of done: documentation and runnable entry points exist, normal CI
syntax-checks the wrappers, and no algorithm/runtime ABI changes are present.

## 6. P2-01: vendor, ABI and capability discovery

Goal: stop inferring Custom features from semantic version numbers.

Preferred UAPI:

```c
#define TCP_BRUTAL_INFO 23303
#define BRUTAL_INFO_ABI_V1 1
#define BRUTAL_VENDOR_UPSTREAM 0
#define BRUTAL_VENDOR_CUSTOM 1

struct brutal_info_v1 {
    __u16 size;
    __u16 abi_version;
    __u32 vendor_id;
    __u32 version;
    __u32 flags;
    __u64 capabilities;
    __u8 build_id[40];
} __packed;
```

Initial capability namespace should reserve bits for per-IP groups, netns,
exact-host hashing, peer stats, manager-level tc aggregate support, peer budget,
prefix index, kernel aggregate pacing and Generic Netlink. Only implemented
features may be advertised.

Build identity must be deterministic. Release/DKMS builds should embed the
verified full Git commit; source builds without a known commit may report an
all-zero build ID. Do not embed timestamps or hostnames.

Add `/proc/net/tcp_brutal/version` for human diagnostics and `brutalctl info` for
CLI inspection. The socket option is the programmatic ABI. Add focused ABI,
short-buffer and capability tests. Do not add Generic Netlink in this phase.

## 7. P2-02: peer resource governance

Goal: bound per-IP peer resource consumption while keeping the default
unlimited behavior compatible with 2.5.3.

Connection-control `.init` cannot reliably reject an already-created TCP
connection, so P2-02 must not advertise a fake `overflow=reject` mode. Initial
policies are `hashed_fallback` (the compatibility default) and optionally
`shared_parent` if implemented and tested.

Add a netns-wide `max_peers=0` limit and optionally a per-rule `maxpeers=0`
limit. Zero means unlimited/inherit according to the documented scope. Slot
reservation state must be separate from observable `active_peers` statistics.

Conceptual creation flow:

```text
lookup existing peer
  -> reserve global slot
  -> reserve rule slot
  -> allocate peer
  -> insert into rhashtable
  -> publish active peer
```

Every duplicate/failure path releases exactly the reservations owned by that
attempt. Final peer destruction releases successful reservations exactly once.
Add pressure/high-watermark/budget-fallback statistics and tests covering the
limit boundary, recovery, races, failslab, rule deletion and netns teardown.

## 8. P2-03: XArray rule-ID index and linear peer iteration

Goal: remove repeated rule-list scanning from peer enumeration and create a
stable indexed rule-ID path.

Add `struct xarray rules_by_id` to per-netns state while keeping the existing
rule list where useful for ordered human output and lifetime management. Do
not reuse live IDs on wrap; fail with `-ENOSPC` rather than alias an active rule.

Rule add/delete must update lookup indexes, XArray and RCU list with complete
rollback on intermediate failure. Peer iteration should use indexed traversal
(e.g. `xa_find_after`) and hold the appropriate group reference while walking
the rule peer table. Target full export complexity is O(per-IP rules + peers),
not O(rules squared + peers).

Add scale tests for unique IDs, reread/seek behavior, deletion races and netns
teardown.

## 9. P2-04: indexed intermediate CIDR lookup

Goal: remove connection-establishment O(N) scans of intermediate CIDR rules.

Keep the current `/0` direct pointer and `/32`/`/128` exact-host fast paths.
The first implementation should use kernel primitives rather than a custom
Patricia trie: a per-netns `rhashtable` keyed by canonical family/prefix length/
masked address plus active prefix-length bitmaps/counters.

Lookup checks only active prefix lengths from longest to shortest. Complexity
is bounded by address width and active prefix-length classes rather than rule
count. RCU publication rules must prevent readers from receiving freed rules;
a reader observing a stale active bit and a hash miss is acceptable.

Only remove the old linear prefix lookup after the indexed implementation is
fully validated. Test IPv4, IPv6, v4-mapped IPv6, longest-prefix selection,
exact overrides, defaults, deletion and large rule sets.

## 10. P2-05: pacer hot/cold-state evaluation

Goal: determine whether `struct brutal_pacer` layout causes measurable cache
contention. This phase is measurement-first and may validly end with no code
change.

On suitable hardware collect `perf stat`, `perf lock` and `perf c2c` evidence
for same-IP and independent-IP loads across 8/16/32 CPUs where available.
Record LLC/cache misses, cacheline bouncing, pacer lock contention, softirq CPU,
throughput and scheduling delay. Report memory footprint at 1k/10k/100k peers.

Do not add cacheline alignment or split the pacer unless evidence shows a useful
benefit (suggested >=5% improvement in the relevant contention metric) without
unacceptable peer-memory growth.

## 11. P2-06A: prepare reservation state for hierarchy

Goal: create storage for a second reservation duration without exceeding
`ICSK_CA_PRIV_SIZE`. Do not enable aggregate pacing in this PR.

Keep precise reservation bookkeeping and recover space elsewhere in `struct
brutal`. A preferred candidate is compact ACK sampling metadata using 16-bit,
wrap-safe second tags while retaining aligned 32-bit ack/loss counters. Reserve
`u32 resv_parent_duration_ns`, zero when hierarchy is inactive.

Run the full RTT/loss matrix, throughput benchmark, dynamic rate changes,
reconnect stress and a long-lived socket test before P2-06B may begin.

## 12. P2-06B: optional hierarchical aggregate pacing

Goal: support a per-IP child limit plus an aggregate rule/group limit inside
Brutal while retaining the existing manager-level `tc` aggregate path.

Suggested CLI semantics:

```text
brutalctl add 0.0.0.0/0 100 perip aggregate=1000
```

The normal `perip` command without `aggregate` preserves existing behavior.
Kernel configuration stores an optional aggregate rate; application groups keep
aggregate disabled unless a future phase explicitly extends them.

For per-IP rules reuse the parent group pacer as the aggregate virtual clock if
possible. For a reserved burst B compute child and parent durations outside
locks. Acquire parent then child, choose the start as the maximum of parent
clock, child clock and bounded lag, advance both clocks, then release in reverse
order. Settlement computes both corrections outside locks and applies them
under the same lock order. Hashed fallback pacers remain aggregate children so
resource pressure cannot bypass the parent cap.

Dynamic enable/disable/rate updates must not create underflow, a large burst,
permanent stall or stale-reservation corruption. Benchmark kernel aggregate
against the existing tc aggregate for CPU, rate accuracy, latency/burst behavior
and non-Brutal traffic semantics. Do not silently migrate existing manager
configurations to the kernel backend.

## 13. P2-07: Generic Netlink control/observation API

Goal: provide a typed machine API for info, stats, rules, peers, limits and
operational events while keeping procfs compatible.

Add a dedicated `brutal_genl.c` and UAPI definitions. Suggested family name is
`tcp_brutal`, version 1. Initial commands: GET_INFO, GET_STATS, RULE_GET,
RULE_DUMP, RULE_ADD, RULE_DEL, PEER_GET, PEER_DUMP, LIMIT_GET and LIMIT_SET.
Attributes must be typed; do not transport proc-style free-form text.

Every request/dump operates in the caller socket namespace. Mutating commands
require `CAP_NET_ADMIN` in the relevant namespace. Large dumps are multipart
and must not snapshot the whole peer table. Events are limited to meaningful
state transitions such as pressure/fallback/allocation failures/rule changes;
hostile-triggerable events must be rate limited.

`brutalctl` probes capabilities and uses Generic Netlink when advertised,
falling back to procfs otherwise. Do not infer support from a semantic version
number and avoid new mandatory third-party userspace libraries.

## 14. P2-08: security model, external-audit scope and stabilization

Add/update `SECURITY.md`, `docs/architecture.md`, `docs/threat-model.md` and this
specification. Cover remote connection/address churn, IPv6 address rotation,
CGNAT, local unprivileged sockets/namespaces, root/operator mistakes and the
source/release/DKMS supply chain.

Explicitly document that per-IP grouping is not user authentication and hashed
fallback is an availability mechanism rather than a strict tenant-isolation
guarantee.

An external kernel review should focus on peer refcounts/RCU, rule lifetime,
netns teardown, XArray/rhashtable publication, resource-slot accounting,
parent/child lock order, reservation settlement, Generic Netlink parsing, fault
paths and module unload. Do not claim an audit occurred without an identifiable
external review.

## 15. CI and acceptance

Build compatibility remains Linux 5.10+, x86_64 and ARM64, GCC and Clang. Debug
runtime continues KASAN+LOCKDEP, KCSAN+LOCKDEP, failslab and lifecycle stress.

Final P2 acceptance requires preserved IPv4/IPv6/per-IP/shared/app-group/netns/
port-routing/tc-aggregate behavior; scale validation at least matching P1; no
Brutal-attributable sanitizer/lockdep/refcount/RCU/Oops signature; correct
resource-pressure recovery; and no unexplained performance regression beyond
the baseline gates.

## 16. Release progression

Recommended milestones:

- 2.6.x: capability identity and peer-resource governance.
- 2.7.x: rule-ID and CIDR indexes.
- 2.8.x: hierarchical kernel aggregate pacing.
- 2.9.x: Generic Netlink API.
- 3.0.0: stabilized P2 architecture and documented ABI/security model.

Release numbering may change, but architectural milestones must remain
separable.

## 17. PR contract

Every P2 PR description must state: phase, measurable problem, scope,
non-goals, structures changed, lifetime/concurrency rules, ABI impact,
performance evidence, exact tests, fault-testing results, rollback and remaining
risks.

Coding agents must inspect current master first, implement only the assigned
phase, preserve unrelated behavior, add focused tests, run format/build/relevant
runtime gates, inspect the final diff and report remaining risks. They must not
remove procfs or current tc aggregate support, change existing socket-option
numbers, drop Linux 5.10 support, change default per-IP semantics, or introduce
speculative lock-free algorithms.

## 18. Dependency order

```text
P2-00
  -> P2-01
  -> P2-02
      -> P2-03 -> P2-04 -> P2-06A -> P2-06B -> P2-07 -> P2-08
      -> P2-05 (measurement branch; may end with no code change)
```

P2-06B must not start until P2-06A independently passes normal and debug
regression coverage.

## 19. Core principle

P2 succeeds when behavior under scale and failure becomes more predictable, not
when the code contains the most sophisticated algorithm. Prefer measured,
bounded, simple, observable and backward-compatible mechanisms over speculative
complexity.
