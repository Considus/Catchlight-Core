# Sync model

A TLA+ model of `SyncEngine` (one Take, two devices, one cloud folder), written from the code in `Sources/CatchlightCore/Sync/` and the app's conflict queue. The header of `CatchlightSync.tla` lists what it models and what it leaves out.

Run it with TLC from `tla2tools.jar` (the TLA+ tools release on GitHub; check its SHA-1 against the release notes) and Java 11 or later. Keep the jar outside the repo:

```bash
java -cp tla2tools.jar tlc2.TLC -workers auto -config CatchlightSync.cfg CatchlightSync.tla
```

| Config | Checks | Today |
|---|---|---|
| `CatchlightSyncStrict.cfg` | Control: no exemption for the designed edit-versus-delete rule, so it must fail. A pass means the model cannot see a loss. | Fails, as it must |
| `CatchlightSync.cfg` | No edit lost unless a user gave it up or a newer deletion removed it; sync never brings back a deleted version. | Fails: known sync bugs |
| `CatchlightSyncLive.cfg` | Once users stop, every device and the folder agree. | Fails: known sync bugs |
| `CatchlightSyncRecords.cfg` | As `CatchlightSync.cfg`, with the per-Take sync record (`FixedRecords`), the manifest entry's `builtOn` (`FixedBuiltOn`), kept deletions (`FixedKeepDeletion`), unread versions never treated as had (`FixedUnreadVersion`) and no lock race. | Passes |
| `CatchlightSyncRecordsUpgrade.cfg` | The same, starting with no records: the first syncs after updating. | Passes |
| `CatchlightSyncRecordsLive.cfg` | Convergence with the record. | Passes |
| `CatchlightSyncRecordsStrict.cfg` | Control with the record: must fail. | Fails, as it must |
| `CatchlightSyncRecordsRaces.cfg` | The same with one lock race (two pushes past the advisory lock at once). | Passes |

The known bugs each get a failing test, added with their fixes. The record configs set `FixedUnverified`, the couldn't-verify queue's fix in Catchlight-iOS. The `Fixed…` constants model proposed fixes, so a fix can be checked here before it is built: set one to `TRUE` and the checker looks for the next problem.

A violation is a lead, not a bug. Read the trace, check the model against the code, then reproduce it with a failing test. Several early violations were mistakes in the model's own properties.
