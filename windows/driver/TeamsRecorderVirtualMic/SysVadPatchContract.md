# SysVAD patch and verification contract

## Immutable upstream input

Bootstrap exactly the Microsoft `windows-driver-samples` commit recorded in
[`sysvad-dependency.lock.json`](sysvad-dependency.lock.json), then initialize
its `wil` submodule. Do not develop against an unpinned `main` checkout. The
bootstrap script verifies these required upstream files before it reports
success:

- `audio/sysvad/sysvad.sln`
- `audio/sysvad/TabletAudioSample/minipairs.h`
- `audio/sysvad/EndpointsCommon/minwavertstream.cpp`
- `audio/sysvad/EndpointsCommon/minwavertstream.h`

The Microsoft sample exposes several devices and generates capture tones. It
is educational source, not a finished virtual-microphone product.

## Required implementation delta

The eventual WDK change must be a reviewable patch series against that exact
commit. It must not ship until every item below has a source diff and a test.

| Area | Required change | Verification |
| --- | --- | --- |
| Endpoint set | Replace the sample's multi-device `g_CaptureEndpoints` setup in `TabletAudioSample/minipairs.h` with one capture-only miniport pair named `Teams Recorder Virtual Microphone`; no render, loopback, AEC, KWS, or sample microphone endpoints. | Device Manager shows one intended media device; Core Audio enumeration has one capture endpoint with the exact name. |
| Audio format | Negotiate only PCM signed 16-bit LE, 48 kHz, stereo, with frame alignment 4 bytes. | Reject every other format in the miniport; capture client validates 48k/2ch/16-bit. |
| PCM source | Replace the capture-tone path in `EndpointsCommon/minwavertstream.cpp` / `WriteBytes` with a bounded nonpaged producer ring. Underrun must write zeros, never a sine tone or stale data. | Deterministic 10-minute underrun/overrun test proves silence on underrun and no stale-frame replay. |
| Producer boundary | Add a narrowly scoped kernel control interface for framed writes from the broker. Use buffered I/O, validate every length/sequence/format at PASSIVE_LEVEL, enforce a bounded queue, and reject `METHOD_NEITHER`, user pointers, format changes, and unbounded allocation. | Fuzz malformed headers, oversize payloads, duplicate/out-of-order sequences, and cancellation; Driver Verifier clean run. |
| Stream lifetime | Tear down producer state on stop/remove before releasing the WaveRT stream; synchronize DPC, ring ownership, and surprise removal. | Repeated open/run/pause/stop/uninstall stress and Driver Verifier run without leaks, use-after-free, or hang. |
| Identity | Keep this INF's exact root hardware ID/service name and expose the exact Core Audio friendly name. The post-install pairing records the Windows-assigned endpoint ID; no friendly-name-only trust. | Capability handshake rejects spoofed name, stale ID, duplicate ID, render endpoint, or mismatched hardware contract. |
| Signing/package | Produce one `.sys`, this INF, and one catalog; run `inf2cat`, sign, and verify the catalog and driver. | `signtool verify /v /pa` succeeds for catalog and driver before install. |

## User-mode broker contract

The current application scaffold implements the producer-side, current-user
named-pipe protocol. The future WDK patch must provide a **separate**
test-only broker process that is the sole client of the kernel control
interface. The recorder application must never open a kernel device directly.

Wire format `TRVM` v1:

- 12-byte little-endian header: magic `TRVM`, `uint16 version`, `uint16 kind`,
  `uint32 payload length`.
- `hello` payload is a 32-byte per-session capability token.
- `pcm` payload is `uint64 sequence` plus at most 19,200 bytes of PCM
  (100 ms at 48 kHz/stereo/16-bit); payloads must be non-empty and aligned to
  four bytes.
- `ack` and `stop` payloads are empty.
- Total payload is capped at 24 KiB. Unknown versions/kinds, wrong token,
  frames before `ack`, malformed payloads, or excess payload close the pipe
  without routing audio.

The broker must use a protected pipe DACL for the current user SID and verify
the local peer. It must map only the validated PCM payload into a bounded
kernel request. It must not log the token, endpoint ID, audio samples, paths,
or credentials.

## Release criteria

This preview cannot become a production virtual microphone based on a
test-signed package. Production requires a separately approved driver security
review, HLK/WHCP work appropriate to the target Windows releases, production
signing/distribution, update/rollback design, and an independent long-duration
audio correctness test. The package signing step must at minimum pass
Microsoft's documented [`signtool verify /v /pa`](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/verifying-the-signature-of-a-test-signed-catalog-file)
checks. Until then, the Release app compile gate remains off.
