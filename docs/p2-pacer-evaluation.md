# P2 pacer hot/cold-state evaluation

P2-05 is measurement-first. The repository keeps `struct brutal_pacer`
unchanged until results show at least a 5% improvement in a relevant contention
metric without unacceptable per-peer memory growth.

Run the repeatable measurement on an otherwise idle 8/16/32 CPU host:

```bash
sudo P2_SECONDS=30 P2_STREAMS=32 tests/pacer-contention.sh
```

The harness runs same-address and independent-address traffic for every
available requested CPU count. It records system identity, throughput,
`perf stat`, `perf lock`, `perf c2c`, `perf sched`, before/after softirq
counters, and projected peer-slab lower bounds for
1k/10k/100k peers. `P2_PERF_DEEP=0` skips the two expensive profiles, and
`P2_DRY_RUN=1` validates the matrix without changing networking state.
Unsupported deep perf facilities are recorded as unavailable while the
remaining profiles continue.

Compare a layout experiment to the unchanged baseline on the same host and
kernel. Report throughput, cache misses, LLC misses when supported, pacer-lock
contention, cacheline HITM samples, and scheduling counters. The memory CSV is
a lower bound for peer slab objects; report allocator and rhashtable overhead
separately when interpreting it.

No pacer layout change is justified without captured before/after evidence.
