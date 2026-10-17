# PiliPlus BTR Turbo

[中文](README.md) | English

An Android derivative of PiliPlus that brings Bilibili-thread-ripper (BTR) download scheduling ideas to the native player, aiming to reduce slow starts and repeated buffering on some overseas connections.

Based on PiliPlus 2.1.6.2. The current release is **1.0.1**; see the [v1.0.1 source branch](https://github.com/Beaulol/PiliPlus_BTR/tree/v1.0.1) and [release notes](https://github.com/Beaulol/PiliPlus_BTR/blob/v1.0.1/version1.0.1.txt).

## What this project adds

- A Dart BTR module that serves ordered media data through a local HTTP proxy to mpv, retaining PiliPlus playback, quality selection, audio tracks and danmaku.
- Concurrent Range downloads, multiple CDN candidates, connection reuse, shared audio/video concurrency limits, retries and fallback handling.
- Compatible mode for player-driven requests, and enhanced mode with bounded block caching, rolling prefetch, slow-block recovery and cancellation after seeking.
- Adaptive concurrency based on playback buffer, bounded by the selected maximum.
- In-player BTR settings that apply at the current position, with scrolling in landscape.
- Download speed beneath the loading indicator, connection/buffer/cache statistics, and a local USB log capture script.

The core scheduling ideas come from BTR; the Android module is implemented in Dart. Enhanced mode manages downloads, while mpv remains responsible for decoding and the playback timeline.

## Usage

Open **⋮ → BTR settings** on the video page, enable acceleration, choose a mode, concurrency settings and CDN group, then apply. Playback reloads at the current position and the settings are saved as defaults.

BTR is disabled by default. Release builds are named **PiliPlus BTR Turbo** and debug builds **BTR Debugger**. They can coexist and keep separate accounts and settings.

Android ARM64 on-demand playback is the main validated target. Live streams, offline media, casting and EDL media retain their existing paths. Partial-block resume, SIDX-based deadline scheduling and BTR URL refresh have not been ported. Results depend on the connection, CDN and bitrate; a controlled comparison with the web version is still pending.

## Development

Switch to the desired version branch before building. See the [BTR documentation](https://github.com/Beaulol/PiliPlus_BTR/blob/v1.0.1/docs/BTR.md) for environment setup, architecture, tests and device validation, and the [changelog](https://github.com/Beaulol/PiliPlus_BTR/blob/v1.0.1/CHANGELOG.md) for changes.

## Acknowledgements

- [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus): the client, player and Bilibili functionality.
- [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper): multi-Range, multi-CDN and playback-oriented scheduling ideas.
- [nishuodedui1145-del/PiliPlus](https://github.com/nishuodedui1145-del/PiliPlus): its open-source work exploring PiliPlus and BTR integration.

Thanks also to [PiliPala](https://github.com/guozhigq/pilipala), [PiliPalaX](https://github.com/orz12/PiliPalaX), upstream contributors and dependency authors.

## License

The original [GPL-3.0 license](LICENSE), source attribution and third-party resource licenses are retained. For the full upstream feature list, please visit the upstream projects.
