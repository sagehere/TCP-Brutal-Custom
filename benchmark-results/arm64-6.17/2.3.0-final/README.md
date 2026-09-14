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

## CPU comparison

The saved baseline and final 2.3.0 iperf3 JSON were generated with the same host, reverse-mode workload, 5 x 60-second runs, 16 streams and 200 Mbps target. In reverse mode the remote/server endpoint is the sender using `brutal`, so the server/sender CPU fields are the relevant comparison.

- sender total CPU median: 0.5512% baseline -> 0.5413% final (about -1.8%)
- sender system CPU median: 0.5374% baseline -> 0.5183% final (about -3.6%)

The differences are small and should be interpreted as no CPU regression, with a slight decrease in this workload, not as a material CPU-performance gain.

## Raw benchmark JSON archive

The five exact final `run-*.json` files are archived losslessly under `raw/` as a Base64-split `tar.xz` archive. The decoded archive SHA-256 is:

`9e3f13fa464dde3b43eb6411c18be4920f167951945a7338676dde9166f92b39`

`raw/README.md` contains reconstruction commands and `raw/SHA256SUMS` records the Base64 archive, decoded archive and each individual run hash. The five Base64 parts total 74,636 bytes.

See `summary.json` and `stats.txt` for the machine-readable summary and final counters.
