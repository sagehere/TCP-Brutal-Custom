# Optimization coverage and validation

Baseline: `459c220`. Release `v2.3.0` is tagged at
`31ee60cd35200acfb78fa4a2334a10e97c2f0e2a`.

The implementation preserves fixed configured rates, same-IP aggregation, and
independent pacing for different peer addresses. The 2.3 work completes all
structural optimization items from the original performance review that can be
implemented and validated on the available two-CPU host without introducing
speculative high-core algorithms.

## Adopted changes

| Review item | Implementation and result |
| --- | --- |
| Parent send statistics | Rule totals use `percpu_counter`; peer totals use their local atomic counter. The parent pacer lock no longer protects statistics. |
| Members and peer counts | Atomic counters replace the pacer lock. Active and peak peer counts are exposed per network namespace. |
| ACK sampling | Every valid ACK contributes to one of four time slots. Full recomputation is limited to 10 ms, configuration changes force refresh, aggregation uses 64-bit arithmetic, and the effective rate is cached per socket. |
| Private socket state | The socket congestion-control state remains guarded by `BUILD_BUG_ON(sizeof(struct brutal) > ICSK_CA_PRIV_SIZE)`. The 12-byte and 20-byte socket parameter ABI is unchanged. |
| Reservation settlement | Settlement uses the duration recorded when the reservation was created. Settle and reserve share one pacer critical section; divisions remain outside the lock. The stale timeout is half the reservation duration, clamped to 2-20 ms. |
| Per-rule peer index | Each per-IP destination rule owns its own automatically resizing `rhashtable`. The peer key contains only address family and address because rule and network namespace are implicit in the owning table. There is no module-wide peer table or peer-table lock. |
| Peer object split | Transmit-hot clock/refcount/member state lives in `struct brutal_pacer`; per-IP objects use the lightweight `struct brutal_peer` and no longer carry application/rule IDs, UID, configuration fields, fallback arrays, or rule statistics. The dedicated peer slab allocates `sizeof(struct brutal_peer)`. |
| Configuration synchronization | Rate, CWND gain, lock state, and generation are read under `seqcount_t` and updated under a dedicated configuration lock. The pacing lock is not used for configuration. |
| Allocation pressure | A dedicated peer slab and 32-object emergency mempool serve atomic peer allocations. Each per-IP rule owns 16 hashed fallback pacers; fallback use is counted explicitly. |
| Peer lifecycle | Last reference is serialized against live reference acquisition by `lifecycle_lock`, then removes the peer from its rule-local table before `call_rcu` reclamation. A same-IP reconnect that collides with a zero-ref peer retries instead of falling back. Rule flush unlinks rules, waits for RCU, then releases groups; per-CPU counters are destroyed from a reclaim workqueue. |
| Network namespaces | Rule lists, rule IDs, exact-host indexes, default pointers, proc entries, counters, peer tables, and application-group indexes are namespace scoped. Host rules and application group IDs do not implicitly cross namespace boundaries. |
| Application groups | The former module-wide `brutal_groups` hash and spinlock are removed. Each network namespace owns an `rhashtable` keyed only by UID and group ID; the final reference removes the object before RCU reclamation. |
| Rule lookup | IPv4 `/32` and IPv6 `/128` rules use one automatically resizing per-netns `rhashtable` keyed by family + address, `/0` rules use direct RCU pointers, and only intermediate CIDRs remain in the longest-prefix list. Large host-exception sets therefore do not lengthen the default-rule scan. |
| Peer monitoring | `/proc/net/tcp_brutal/peers` uses a real `seq_operations` iterator. Each open holds the namespace and at most the current group/peer, pauses and resumes the `rhashtable` walker across reads, supports seek/reread, and never allocates a whole-table snapshot. `brutalctl peers` retains `--rule`, `--ip`, `--family`, and `--limit`. |
| Diagnostics | `/proc/net/tcp_brutal/stats` reports allocation failures, insertion failures, fallback connections, active peers, and peak peers. |

All adopted structural items are implemented in the current master tree.

## Deliberate exclusions

These are not incomplete implementation work. They require evidence that the
extra algorithmic or ABI complexity is justified.

| Candidate | Decision |
| --- | --- |
| Idle peer cache | Keep disabled. Immediate RCU reclamation avoids retaining attacker-controlled addresses. Reconsider only if short-flow allocation profiling shows a material cost. |
| CAS virtual clock | Do not replace the pacer spinlock without >2 CPU contention measurements. Correct reservation compensation and fairness are more important than speculative lock removal. |
| Batch credit | Do not enable by default without high-contention data. It can reduce lock frequency but changes burst and fairness behavior. |
| EWMA ACK estimator | Keep the four-slot estimator until loss/RTT tests demonstrate a stability problem that EWMA solves. |
| Fixed-point reciprocal | Keep accurate 64-bit division outside the pacer lock unless profiling shows it is a material CPU consumer across the supported rate range. |
| Generic Netlink | Added in P2 as a typed, namespace-scoped API for info, stats, rules, peers, limits and configuration events. Procfs remains the compatible fallback. |
| Bandwidth probing or automatic capacity discovery | Excluded. ACK success is a loss signal and does not measure spare path capacity. |

## Continuous build validation

Every push and pull request builds the module against:

- Linux 5.10 / x86 / GCC
- Linux 6.1 / x86 / Clang
- Linux 6.6 / ARM64 / GCC
- Linux 6.12 / ARM64 / Clang
- Linux 7.2 / x86 / GCC

The userspace job builds `brutalctl`, compiles the application-group namespace
test helper with warnings as errors, and runs the installer/manager tests.
Formatting is checked separately with clang-format 18.

The merge commit `510f5e25e75f2537a1b802d1ce174b8ed3a1db64` passed both
`Build and test` and `Check formatting` on the master push.

## Runtime validation on the two-CPU ARM64 host

The repository runtime suite now contains:

- `tests/netns-integration.sh`: namespace isolation, prefix normalization,
  exact-host priority, same-IP multi-stream rate sharing, live rate changes,
  peer reporting and cleanup.
- `tests/app-group-netns.sh`: two namespaces use the same application group ID
  with different configured rates and verify that neither namespace changes
  the other's group.
- `tests/peer-churn.sh`: repeatedly creates and retires large numbers of
  distinct per-IP groups, then checks live-peer and failure counters.
- `tests/peer-reconnect-race.sh`: concurrent same-IP reconnect/last-close
  lifecycle stress; unexpected fallback is a failure.
- `tests/exact-host-scale.sh`: large IPv4 `/32` and IPv6 `/128` rule population,
  lookup, count and flush validation.
- `tests/peer-pagination.sh`: holds many peers concurrently, reads the proc file
  in tiny chunks, seeks to zero and requires the same exact unique stable set.
- `tests/benchmark.sh`: repeated same-IP multi-stream throughput measurements.
- `tests/two-cpu-validation.sh`: runs the complete sequence with conservative
  defaults suitable for a 2-vCPU VPS.

Final release-scale runtime validation was performed on ARM64/aarch64,
Linux `6.17.0-1020-oracle`:

- namespace and per-IP integration: PASS
- application-group namespace isolation: PASS
- peer churn: PASS, 10,000 peer addresses
- same-IP reconnect race: PASS, 80,000 connections (`8 x 10,000`)
- exact-host scale: PASS, 10,000 IPv4 `/32` + 256 IPv6 `/128` rules
- pageable peer iterator: PASS, 1,000 simultaneously active peers with tiny
  reads and `lseek(fd, 0)` reread
- kernel log safety scan: PASS; no BUG, WARNING, Oops, RCU stall, refcount/UAF
  or general-protection matches
- final normal-memory counters: zero allocation failures, zero insertion
  failures, zero fallback connections, and zero active peer groups after cleanup

The first 80k reconnect attempt hit client-side `EADDRNOTAVAIL` because the test
client actively closed every connection and exhausted ephemeral ports/TIME_WAIT.
The test was corrected to wait for the server active close, and the repeated 80k
run passed. No module defect was involved.

## Final ARM64 throughput and CPU measurement

Five 60-second runs with 16 same-IP streams and a 200 Mbps target produced:

| Build | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| `459c220` baseline | 199.750 Mbps | 199.787 Mbps | 199.855 Mbps |
| 2.3.0 final candidate | 199.750 Mbps | 199.820 Mbps | 199.839 Mbps |

The final 2.3.0 candidate median is within normal run-to-run variation of the
saved baseline. Worst target error was about 0.125%, so no measurable throughput
regression was observed.

The same saved iperf3 JSON records also provide a consistent CPU comparison.
The benchmark uses reverse mode: the remote/server endpoint is the sender using
`brutal`, so its CPU utilization is the relevant metric.

| Metric | `459c220` baseline median | 2.3.0 final median | Relative change |
| --- | ---: | ---: | ---: |
| Sender total CPU | 0.5512% | 0.5413% | about -1.8% |
| Sender system CPU | 0.5374% | 0.5183% | about -3.6% |

These small differences establish no CPU regression on the available host and
workload. They are not presented as a material CPU-performance improvement.

The aggregate release evidence, final counters, and exact raw benchmark input
are stored under `benchmark-results/arm64-6.17/2.3.0-final/`. The five final
`run-*.json` files are preserved losslessly in the `raw/` archive; its decoded
`tar.xz` SHA-256 is
`9e3f13fa464dde3b43eb6411c18be4920f167951945a7338676dde9166f92b39`.
`raw/SHA256SUMS` records hashes for the encoded archive, decoded archive, and
each individual run.

## Validation still requiring dedicated environments

The current two-CPU VPS cannot establish these claims, so they remain explicit
hardware-validation items rather than release blockers for the structural code:

- 8/16/32+ CPU SMP scaling and high-core pacer contention
- NUMA behavior and cross-socket cache-line traffic
- 10/25/40-Gbit physical-NIC throughput
- KASAN, KCSAN, LOCKDEP and KMEMLEAK debug-kernel runs
- deliberate slab/page allocation fault injection
- complete RTT/loss matrix with `tc netem`

No linear high-core scaling, NUMA behavior, or 10-Gbit claim should be made
until those environments are actually tested.

## Release acceptance for 2.3.0

Final release status:

1. GitHub compile, userspace, and formatting jobs: **PASS**.
2. Release-scale two-CPU validation including 10,000 peer churn, 80,000
   reconnects, 10,000 exact-host rules, 1,000-peer pagination, and five
   60-second benchmark repetitions: **PASS**.
3. Peer allocation/insertion failures and unexpected fallback during the
   normal-memory run: **ZERO / PASS**.
4. Throughput compared with the saved baseline: **PASS**, configured-rate error
   well below 1% and no measurable throughput regression.
5. Aggregate benchmark summary and final proc stats saved with release evidence:
   **PASS**.
6. Full raw final-run iperf JSON archival with per-file SHA-256 verification:
   **PASS**.
7. Dedicated CPU-utilization comparison against the saved baseline: **PASS**;
   no CPU regression was measured on the available host/workload.
8. Git tag / GitHub Release: **PASS**; `v2.3.0` targets
   `31ee60cd35200acfb78fa4a2334a10e97c2f0e2a` and the published release is
   non-draft and non-prerelease.

Release `v2.3.0` was published after the evidence merge and its CI passed. The
tag points to `31ee60cd35200acfb78fa4a2334a10e97c2f0e2a`; later master commits are
release housekeeping only and do not alter the tagged release tree.

## Rollback

Unload the candidate after stopping users of `brutal`, load a saved module or
an installed known-good DKMS version, restore the saved rules, and restart the
affected service. During validation, keep an installed known-good DKMS build as
the persistent rollback target until the new build has survived reboot and
service restoration.
