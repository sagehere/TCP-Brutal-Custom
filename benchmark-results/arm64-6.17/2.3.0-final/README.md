# TCP Brutal Custom 2.3.0 final ARM64 validation

This directory records the final release-validation evidence for the 2.3.0 structural work on the available 2-vCPU ARM64 host.

## Build under test

- Release commit: `510f5e25e75f2537a1b802d1ce174b8ed3a1db64`
- Release tree: `5075c071bf939773de792053df6795f15073aa5e`
- Kernel-code commit used for the loaded module: `291c7fcf2dff70204163fcc5d22f744d0d1b48da`
- The only delta between the loaded kernel-code commit and the merged PR head was the reconnect stress-test harness fix; module C/header code was unchanged.
- Architecture: aarch64
- Kernel: `6.17.0-1020-oracle`
- Loaded module srcversion: `4FB82A86B00E34CBA2A462C`

## Correctness and stress validation

- Namespace and per-IP integration: PASS
  - 50 Mbps aggregate target: about 49.868 Mbps
  - exact-host 40 Mbps priority: about 39.854 Mbps
  - live update to 30 Mbps: about 29.847 Mbps
- Application-group namespace isolation: PASS
- Peer lifecycle churn: PASS, 10,000 peer addresses
- Same-IP reconnect race: PASS, 80,000 connections (`8 x 10,000`)
- Exact-host index growth: PASS, 10,000 IPv4 `/32` plus 256 IPv6 `/128` rules
- Paginated peer proc iterator: PASS, 1,000 simultaneously active peers, tiny reads plus `lseek(fd, 0)` reread
- Kernel safety log scan: PASS, no BUG/WARNING/Oops/RCU-stall/refcount/UAF/general-protection matches

The first 80k reconnect attempt exhausted client ephemeral ports because the test client actively closed each connection. The test harness was changed to wait for the server active close; the repeated 80k run then passed. This was a test-harness issue, not a module failure.

## Throughput regression gate

Configuration: 5 runs, 60 seconds per run, 16 streams, 200 Mbps target.

Verified aggregate from the benchmark script:

- runs: 5
- median: 199.820192829 Mbps
- minimum: 199.750402156 Mbps
- maximum: 199.839483972 Mbps
- worst target error: about 0.125%

Saved baseline median on the same ARM64/6.17 host: 199.787457 Mbps. No measurable throughput regression was observed.

See `summary.json` and `stats.txt` for machine-readable summary and final counters.

## Raw benchmark JSON status

The five full iperf JSON files from the final run remain on the test host and are not copied into this directory yet. The host's Remote Desktop Commander channel was offline when this evidence bundle was created, so this directory intentionally records only values already captured from the benchmark script and PR runtime-validation log. Do not substitute the older `candidate/` JSON files for the final 2.3.0 run.

Copy the five final `run-*.json` files here before creating the final release tag if full raw-run archival is required by the release policy.