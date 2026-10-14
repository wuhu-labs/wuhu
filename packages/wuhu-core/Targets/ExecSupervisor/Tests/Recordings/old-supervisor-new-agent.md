# Published dev.113 supervisor / real installer uninstall recording

Recorded on 2026-10-14 on the authorized disposable Linux scratch host with a real user systemd manager, using the driver’s explicit `--service-proof real-manager` mode. This is supplemental regression provenance, not final-head rollout proof.

The candidate is the clean static build of `a3c7c00ec04f824c768d4b50c323d44cd93d2e36`, binary SHA256 `d85b23fd1a6b1d05f524b5ffd90313a092ea2b537162b248b043fe31cc39d593`; its full embedded source stamp was checked on the scratch host. The source archive SHA256 is `3d4d6f0c5c8b5ef8c7dd5fae9ea8f4b96be06044817d4ba54fc27dc0b31745e8`. The driver additionally contains the later explicit Linux logical-boundary / real-manager mode selection; the candidate runtime is unchanged by that selection.

The previous supervisor is the actual published `wuhu-0.1.0-dev.113-linux-amd64.tar.gz`, downloaded from the public release URL and verified against archive SHA256 `9cdb71c3efa51687ddb6babc15efa7636f8bf8dd281b8c002bd7af8f280dcf8f`. Its executable SHA256 and approved historical version/source stamp are in the JSON recording’s `oldSupervisor` effect. No rebuilt baseline or current-binary substitute was used.

The 48 recorded handler exchanges cover both full output rings, 42,000 pending stdin bytes, byte-exact output, and output acknowledgement followed by an explicit still-not-drained observation before the accepted matching terminal acknowledgement. The actual installed candidate CLI invokes `machine-v2 uninstall`; the real isolated systemd service and its definition must remain present until drain and server acknowledgement complete, then the manager reports stopped and the installer has removed the definition. `realUninstall` records the observed CLI exit and manager/file outcomes. No production machine, enrollment, tunnel or server is involved.

The final-head scratch run and macOS launchd proof must be repeated after the final source freeze; this fixture never claims those later live results.
