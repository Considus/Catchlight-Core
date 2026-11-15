# Sync model

A TLA+ model of `SyncEngine` (one Take, two devices, one cloud folder), written from the code in `Sources/CatchlightCore/Sync/`. The header of `CatchlightSync.tla` lists what it models and what it leaves out.

Run it with the TLC model checker from `tla2tools.jar` (the TLA+ tools release on GitHub) and Java 11 or later:

```bash
java -cp tla2tools.jar tlc2.TLC -workers auto -config CatchlightSync.cfg CatchlightSync.tla
java -cp tla2tools.jar tlc2.TLC -workers auto -config CatchlightSyncStrict.cfg CatchlightSync.tla
java -cp tla2tools.jar tlc2.TLC -workers auto -config CatchlightSyncLive.cfg CatchlightSync.tla
```

- `CatchlightSync.cfg`: no edit lost unless a user gave it up or a newer deletion removed it, and no deleted note comes back.
- `CatchlightSyncStrict.cfg`: a control run that must fail, proving the checker can see a loss.
- `CatchlightSyncLive.cfg`: once users stop, every device and the folder agree.

A violation is a lead, not a bug: reproduce it with a failing test in `Tests/` first.
