# P2 baseline

P2 development starts from master commit
`65df326567df1a38dd2f227922723d1040bbacb9`, the merge of P1 PR #13.
The source version at this baseline is `2.5.3`.

This file defines the immutable comparison point for P2. Feature branches may
add measurements, but they must not rewrite the baseline commit or reinterpret
P1 evidence after the fact.

## P1 evidence carried into P2

The merged P1 validation established the following on the available ARM64,
2-vCPU Linux 6.17 host and in debug-kernel CI:

- 10,000 active per-IP peers passed.
- 10,000 distinct-address peer churn passed.
- 80,000 same-peer reconnects passed.
- namespace and application-group isolation passed.
- the RTT/loss matrix (1/50/200 ms x 0/1/5/20%) passed.
- the 128-stream throughput decline was reproducible with Reno/BBR controls;
  perf did not identify Brutal code or Brutal locks as a material hotspot at
  the tested 200 Mbps rate.
- Linux 6.12 debug-runtime CI passed with KASAN + LOCKDEP and KCSAN + LOCKDEP.
- targeted peer-slab failslab testing exhausted the peer mempool reserve and
  exercised the fallback path without a Brutal safety signature.
- 100 module/netns lifecycle teardown cycles passed.

These results do not establish high-core, NUMA, or 10/25/40-Gbit scaling. P2
must continue to treat those as dedicated-hardware validation items.

## Source-level baseline invariants

At the baseline commit:

- `struct brutal` is compile-time constrained by
  `BUILD_BUG_ON(sizeof(struct brutal) > ICSK_CA_PRIV_SIZE)`.
- `/0` destination rules use direct RCU pointers.
- IPv4 `/32` and IPv6 `/128` rules use a per-netns `rhashtable`.
- intermediate CIDRs still use the RCU prefix list.
- each per-IP rule owns its peer `rhashtable`.
- peer allocation uses a dedicated slab/mempool and 16 hashed fallback pacers
  per per-IP rule.
- application groups and destination rules are namespace scoped.
- the current manager-level aggregate egress limit is implemented with a
  guarded `tc` egress filter and remains the P2 compatibility fallback.

## P2 performance gates

Unless a change explicitly alters semantics and documents why, compare the
candidate against this baseline using repeated runs and medians. The default
release gates are:

| Metric | Gate |
| --- | --- |
| Throughput regression | less than 1% |
| Sender CPU regression | less than 3% |
| Configured-rate error | less than 1% |
| Normal-memory peer fallback | zero |
| Normal-memory peer allocation failure | zero |
| Brutal-attributable kernel warning/Oops/sanitizer report | zero |

Microbenchmark results are evidence, not automatic release blockers: noisy or
hardware-specific results must include the raw data and environment before a
conclusion is made.

## Reproducible P2 entry points

The P2 baseline adds four wrappers without changing the congestion-control
algorithm:

```sh
sudo bash tests/p2-regression.sh
sudo P2_FULL=1 bash tests/p2-regression.sh
sudo bash tests/p2-rule-scale.sh
sudo bash tests/p2-peer-scale.sh
sudo bash tests/p2-peer-dump-scale.sh
```

`P2_DRY_RUN=1` is supported by every new wrapper so ordinary userspace CI can
validate orchestration without a loaded Brutal module or privileged network
namespace operations.

`P2_EXTREME=1` opts into the largest scale point in the scale wrappers. It is
not part of the ordinary pull-request gate because CI and small VPS hosts may
not have the resources to execute it reliably.

## Required result metadata

Any committed P2 benchmark result must state at least:

- candidate commit SHA;
- baseline commit SHA;
- architecture and CPU count;
- kernel release;
- compiler when relevant;
- exact test command and environment overrides;
- run count and run duration;
- raw-result location;
- median and range for reported performance metrics.

Do not claim high-core or high-bandwidth scalability from the two-vCPU P1/P2
baseline environment.
