# Optimization coverage and validation

Baseline: `459c220`. Version: `2.2.0`. The implementation preserves fixed
configured rates, same-IP aggregation, and independent pacing for different
peer addresses.

## Adopted changes

| Report 1 item | Implementation and result |
| --- | --- |
| Parent send statistics | Rule totals use `percpu_counter`; peer totals use their local atomic counter. The parent pacer lock no longer protects statistics. |
| Members and peer counts | Atomic counters replace the pacer lock. Active and peak peer counts are exposed per network namespace. |
| ACK sampling | Every valid ACK contributes to one of four time slots. Full recomputation is limited to 10 ms, and configuration changes force the next ACK or send opportunity to refresh. Aggregation and multiplication use 64-bit arithmetic. |
| Effective rate | Cached per socket and refreshed with ACK loss data or the group configuration generation. A generation fence prevents a completed update from being observed with stale fields on weakly ordered CPUs. |
| Private state size | The socket state is 104 bytes and guarded by a build assertion against `ICSK_CA_PRIV_SIZE`. The 12-byte and 20-byte socket parameter ABI is unchanged. |
| Reservation settlement | Settlement uses the duration recorded when the reservation was created. Normal send, group change, and close paths account final bytes and return unused time without unsigned clock underflow. |
| Pacer critical section | Settlement and the next reservation share one critical section. Burst estimation and divisions run before the lock. |
| Stale reservation | Half the reservation duration, clamped from 2 to 20 ms. |
| Peer index | The fixed 256-bucket table and global lock are replaced by an automatically resizing `rhashtable`. Its canonical key includes the rule, network namespace, address family, and address. Lookup takes a nonzero reference under RCU; insertion races and retiring entries have explicit paths. |
| Allocation pressure | A dedicated peer slab and 32-object emergency pool serve atomic allocations. Each per-IP rule also owns 16 fallback pacers selected by an address hash; collisions share a rate and are reported rather than claimed as strict isolation. |
| Peer lifecycle | Last reference removes the peer from the hash and uses `call_rcu`. Rule flush unlinks every rule, waits for one RCU grace period, then releases groups. A dedicated reclaim workqueue destroys per-CPU counters in process context, and module exit drains callbacks and work before destroying caches. |
| Network namespaces | Rule lists, rule IDs, exact-host indexes, default pointers, proc entries, and counters are per namespace. Application groups remain keyed by UID, group ID, and namespace. Host rules do not implicitly configure containers. |
| Rule lookup | `/32` and `/128` rules use RCU hash indexes, default rules use direct RCU pointers, and other CIDRs retain longest-prefix matching. Prefixes are canonicalized before insertion. IPv4-mapped IPv6 uses IPv4 grouping. |
| Peer monitoring | Proc output uses a `seq_file` iterator over the hash instead of allocating a full-table snapshot, and retries hash resize events. It is a live view. `brutalctl peers` supports `--rule`, `--ip`, `--family`, and `--limit`; the manager defaults to 1000 rows and reports truncation. |
| Diagnostics | `/proc/net/tcp_brutal/stats` reports allocation failures, insertion failures, fallback connections, active peers, and peak peers. Rule output retains its original fields and appends no incompatible format changes. |

## Deliberate exclusions

| Candidate | Decision |
| --- | --- |
| Idle peer cache | Disabled. Immediate RCU reclamation passed repeated connection tests and avoids retaining attacker-controlled addresses. |
| CAS clock and batch credit | Kept out of the default implementation. Correct compensation, return, close recovery, and fairness add substantial state; the two-core host cannot establish the high-core benefit needed to justify that risk. |
| EWMA ACK estimator | The four-slot estimator remains the default. It has explicit expiry behavior and met the rate-error target; no measured instability justified changing its response curve. |
| Fixed-point reciprocal | The full supported range includes rates where a simple integer nanoseconds-per-byte reciprocal loses material precision. The 64-bit division stays outside the lock instead. |
| Generic Netlink | Deferred. The delivered proc ABI is namespace-aware and the CLI performs bounded export and filtering. A versioned Netlink family should be added with a real event or large-dump consumer rather than maintained as a second unconsumed write API. |
| Bandwidth probing, extra burst knobs, qdisc rewriting | Excluded from defaults. ACK success does not measure spare link capacity, and the tested host already uses `fq`. |

## ARM64 validation

The module builds against Ubuntu 24.04 kernel `6.17.0-1020-oracle` on ARM64
(Neoverse-N1, two CPUs). The integration test covers namespace isolation,
prefix normalization, exact-host priority, four same-IP streams, active peer
reporting, peer cleanup, and a live rate change from 50 to 30 Mbps. It held
the 50 Mbps phase near 49.9 Mbps and passed the 40 Mbps exact-host and 30 Mbps
post-update bounds without allocation, insertion, or fallback errors.

Five 60-second measurements per build with 16 same-IP streams and a 200 Mbps
target produced:

| Build | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| `459c220` | 199.750 Mbps | 199.787 Mbps | 199.855 Mbps |
| Candidate | 199.718 Mbps | 199.804 Mbps | 199.820 Mbps |

The candidate median differs by +0.008%, within run-to-run variation, and the
configured-rate error is below 0.15%. Full iperf3 JSON is under
`benchmark-results/arm64-6.17/`. Run `sudo tests/netns-integration.sh` for the
correctness suite and `sudo tests/benchmark.sh LABEL` for the repeated test.

KASAN, KCSAN, LOCKDEP, KMEMLEAK, deliberate OOM injection, loss/RTT matrices,
10,000-address churn, and high-core scaling require separate debug or larger
hosts. No claim about linear CPU scaling or 10-Gbit throughput is based on this
two-core measurement.

## Rollback

Unload the candidate after stopping users of `brutal`, load the saved module or
the installed DKMS version, restore the saved rules, and restart the affected
service. The test host backup is in `/root/tcp-brutal-backup-20260913`; candidate
tests load from `/tmp`, so the installed DKMS module remains the persistent
rollback target.
