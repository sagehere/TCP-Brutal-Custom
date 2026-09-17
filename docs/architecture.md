# Architecture

TCP Brutal Custom is a Linux TCP congestion-control module with optional
destination rules. Existing socket ABI numbers remain compatible with upstream
TCP Brutal; Custom features are discovered through `TCP_BRUTAL_INFO` capability
bits rather than version guesses.

## Data path

When a socket initializes, destination lookup runs under RCU in this order:

1. exact IPv4 `/32` or IPv6 `/128` host hash;
2. active intermediate prefix lengths, longest first, through the canonical
   prefix rhashtable;
3. the direct `/0` family default pointer.

The active-prefix bitmaps bound lookup by address width and active length
classes. Lookup never scans the number of installed rules. A socket holds its
pacer reference after matching, so later rule removal does not invalidate an
existing connection.

A shared rule points directly at its group pacer. A `perip` rule maps the peer
address to a lightweight peer pacer in the rule's rhashtable. Same-address
connections share that child. Allocation first reserves namespace and rule
slots, then allocates and inserts the peer. Every failure path releases only
its own reservations. Final peer removal is serialized by `lifecycle_lock`,
removed from the hash, and reclaimed after RCU.

When a peer cannot be allocated or a budget is exhausted, a stable address
hash selects one of 16 fallback pacers. This bounds memory while keeping the
connection usable. Fallback collisions intentionally share pacing state.

## Pacing hierarchy

Each pacer owns a virtual clock protected by its spinlock. Ordinary shared and
per-socket modes reserve only one clock. With `perip aggregate=N`, the rule
group pacer is the aggregate parent and the address or fallback pacer is the
child. Reservation durations are calculated before locking; locks are always
acquired parent then child and released in reverse order. Settlement corrects
both reservations with the same order. Disabling or changing the aggregate
rate advances generations so live sockets refresh configuration without stale
parent reservations.

The congestion-control private state has a compile-time
`ICSK_CA_PRIV_SIZE` bound. The second reservation duration was added by
compacting ACK sample timestamps to wrap-safe 16-bit second tags; the build
assertion remains the authority for each supported kernel.

## Control plane

Rules have monotonic, non-reused IDs in a per-namespace XArray. The RCU list is
retained for ordered human output, while rule lookup and peer pagination use
the XArray and rhashtables.

Three interfaces coexist:

- socket options preserve the application ABI and expose stable capability
  discovery;
- `/proc/net/tcp_brutal` remains the compatible human and fallback interface;
- Generic Netlink family `tcp_brutal`, version 1, provides typed info, stats,
  rule, peer, and limit operations plus rule/limit change events.

Generic Netlink dumps stream entries rather than copying the complete table.
All operations resolve state from the caller socket's network namespace.
Mutations require `CAP_NET_ADMIN` in that namespace. `brutalctl` probes the
advertised family and uses it when available, otherwise it uses procfs.

## Namespace and lifetime ownership

Every namespace owns its rules, XArray, exact and prefix hashes, application
groups, budgets, counters, and proc entries. Rule configuration is serialized
by the namespace rule mutex. Packet lookup uses RCU; pacer configuration uses
a seqcount plus a writer spinlock; virtual clocks use pacer spinlocks.

Module initialization registers socket options, per-network-namespace rule
state, Generic Netlink, and finally the congestion-control algorithm. Failure
unwinds in reverse order. Module exit first stops new congestion-control users,
then unregisters Netlink and destroys namespace state after readers and held
references have drained.

## Manager-level aggregate control

The existing `tc` egress aggregate is separate from kernel hierarchical
pacing. The former protects an interface and can affect non-Brutal traffic;
the latter caps children of one Brutal rule. Configuration is never migrated
between them implicitly.
