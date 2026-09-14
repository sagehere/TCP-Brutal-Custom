# Final raw iperf3 archive

The final 2.3.0 benchmark consists of five full iperf3 JSON files from the 5 x 60-second, 16-stream, 200 Mbps release run on ARM64/Linux 6.17.

The lossless `final-run-json.tar.xz` archive is stored as five Base64 text parts because the repository connector used for release evidence cannot directly write the binary archive.

Reconstruct and verify it from this directory:

```bash
cat final-run-json.tar.xz.b64.part* > final-run-json.tar.xz.b64
sha256sum -c <(grep 'final-run-json.tar.xz.b64$' SHA256SUMS)
base64 -d final-run-json.tar.xz.b64 > final-run-json.tar.xz
sha256sum -c <(grep 'final-run-json.tar.xz$' SHA256SUMS)
tar -xJf final-run-json.tar.xz
sha256sum -c <(grep 'run-[1-5].json$' SHA256SUMS)
```

Expected Base64 size: 74,636 bytes, split as 16,000 / 16,000 / 16,000 / 16,000 / 10,636 bytes.

The archive SHA-256 is `9e3f13fa464dde3b43eb6411c18be4920f167951945a7338676dde9166f92b39`. The per-run hashes in `SHA256SUMS` identify the exact raw files used for the final throughput and CPU comparison.
