# P2 validation record

Validation date: 2026-09-17

P2 was built and exercised in Ubuntu 26.04 under WSL2 on a 12-vCPU x86_64
host. The running kernel was `6.6.87.2-microsoft-standard-WSL2`. The matching
Microsoft kernel source and exported symbol versions were used to build the
loadable module; its `vermagic` exactly matched the running kernel.

## Build results

- The userspace client passed GCC and Clang builds with
  `-Wall -Wextra -Werror -std=c99 -pedantic`.
- The module passed a `W=1` build against Ubuntu 7.0 headers.
- Source-native compatibility builds passed for Linux 5.10.269 with GCC and
  Linux 6.1.187 with Clang.
- The module passed a `W=1` build against the matching WSL kernel source and
  loaded successfully.

## Runtime results

The following tests passed with the module loaded:

- ABI discovery through Generic Netlink and connected IPv4/IPv6 socket ABI
- Generic Netlink namespace isolation and typed rule/limit operations
- namespace and per-IP correctness
- application-group namespace isolation
- peer budget and hashed fallback behavior
- rule-ID XArray lookup and iteration
- intermediate IPv4/IPv6 prefix indexing
- optional kernel aggregate pacing
- peer lifecycle churn and same-peer concurrent reconnect
- exact-host index growth and paginated peer reads

The reduced two-CPU suite used 200 peer addresses, 400 reconnects, 256 IPv4
plus 256 IPv6 exact-host rules, 64 simultaneously visible peers, and one
five-second eight-stream throughput run. It completed without module warnings,
resource leaks, or fallback/allocation failures. The throughput sample was
98.96 Mbit/s for a configured 100 Mbit/s shared destination.

## Pacer contention evidence

The 8-CPU matrix used eight streams for five seconds at 100 Mbit/s per pacer:

| Workload | Throughput | Cycles | Instructions | Cache misses | Context switches |
| --- | ---: | ---: | ---: | ---: | ---: |
| Same IP/shared pacer | 101.82 Mbit/s | 3,346,212,930 | 1,329,718,605 | 79,321,645 | 14,978 |
| Independent IP/pacers | 799.33 Mbit/s | 8,953,797,753 | 3,426,865,088 | 229,021,494 | 101,817 |

The measured peer slab object size was 112 bytes, giving lower bounds of
112,000 bytes for 1,000 peers, 1,120,000 bytes for 10,000 peers, and
11,200,000 bytes for 100,000 peers.

`perf lock` and `perf sched` both captured reports in the three-second deep
profile. WSL's virtual PMU reported that no PMU supports the memory events
required by `perf c2c`; the harness records that capability as unavailable and
continues the other profiles.

## Remaining release evidence

This run validates functional runtime behavior and an 8-vCPU contention
sample. It does not replace 16/32-core bare-metal or VM testing, NUMA and
10/25/40-Gbit measurements, `perf c2c` on a supported PMU, or KASAN, KCSAN,
LOCKDEP, failslab, and RCU-stall debug-kernel runs. Those remain release
promotion evidence rather than unimplemented P2 work.
