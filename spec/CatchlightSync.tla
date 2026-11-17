--------------------------- MODULE CatchlightSync ---------------------------
(***************************************************************************)
(* One Take, several devices, one shared cloud folder: the SyncEngine of   *)
(* Catchlight-Core as the code stands (Sources/CatchlightCore/Sync/).       *)
(*                                                                         *)
(* Modelled: the manifest (one entry or one tombstone for the Take), the   *)
(* blob file, each device's store (the Take, its pending tombstone, the    *)
(* last-sync watermark), the advisory lock, the app's conflict queue and   *)
(* its "couldn't verify" queue, and user edits, deletions and choices.     *)
(* sync() is split where other devices can act in between: the pull reads  *)
(* the manifest, then the blob; the push plans from one snapshot, writes   *)
(* or deletes the blob, then writes the manifest. A push can be cancelled  *)
(* between those steps (background task expiry).                           *)
(*                                                                         *)
(* Left out: Scripts, the Obie flag, tombstone retention and the long-     *)
(* offline hold-back, clock skew (one global clock), crashes inside the    *)
(* store, and more than one Take. The push reads the device's store once,  *)
(* at its start, where the code reads it at steps 1 and 3.                 *)
(*                                                                         *)
(* FixedRecords models the per-Take sync record (SyncRecord.swift): versions *)
(* are named by their edit stamp, and each device records the version it  *)
(* last agreed with and its own upload not yet seen in a pull.            *)
(*                                                                         *)
(* Content ids: every user edit makes a new content, numbered by the clock *)
(* tick it was made at, so a content can be traced wherever it is copied.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Dev,            \* the devices, e.g. {d1, d2}
    NoVal,          \* model value: "nothing here"
    MaxTime,        \* clock ticks available to edits and deletions
    MaxResolves,    \* conflict choices the user may make in one behaviour
    MaxRaces,       \* times two pushes may both pass the advisory lock
    AllowBlobLag,   \* TRUE: a pull may find the blob not yet readable (skipped)
    EditWhileHeld,  \* TRUE: the user may edit a Take waiting in the conflict queue
    FixedPushStep1, \* TRUE: model the proposed fix: push step 1 holds a Take whose folder
                    \* entry changed since the last sync, as a conflict, instead of uploading
    FixedUnverified,\* TRUE: model the proposed fix: Keep and Recover on an unverified copy
                    \* act only while the Take is still the version that was queued
    SerialSyncs,    \* TRUE: one sync at a time (the convergence run: overlapping syncs
                    \* let a hostile schedule starve one device's push of the lock forever)
    UpgradeStart,   \* TRUE (with FixedRecords): both devices start with no records, as on
                    \* the first sync after updating from a build without them
    FixedRecords    \* TRUE: model the per-Take sync record (SyncRecord.swift): each device
                    \* compares with the version it last agreed with, not edit times with
                    \* its last-sync time, and push never uploads over a version it has not had

VARIABLES
    now,        \* global clock; ticks only on user actions
    local,      \* [Dev -> version or NoVal]: the Take in each device's store
    tomb,       \* [Dev -> time or NoVal]: pending local tombstone (deletedAt)
    lastSync,   \* [Dev -> time]: store.lastSyncDate()
    pair,       \* [Dev -> [l, r] or NoVal]: conflict queue entry (held)
    unv,        \* [Dev -> [l, r] or NoVal]: "couldn't verify" queue entry
    blob,       \* the .clk file in the folder: version or NoVal
    mEntry,     \* manifest entry for the Take: version (its HMAC names it) or NoVal
    mTomb,      \* manifest tombstone: deletedAt or NoVal
    lock,       \* catchlight.lock holder or NoVal
    pc,         \* [Dev -> "idle" | "pullBlob" | "push" | "pushBlob" | "pushManifest"]
    pullSnap,   \* [Dev -> what the pull read at its start]
    pushPlan,   \* [Dev -> what the push decided at its start]
    repair,     \* [Dev -> BOOLEAN]: report.repairCandidates, pull to push
    races,      \* lock races used
    resolves,   \* conflict choices used
    authored,   \* every content a user has written
    discarded,  \* contents a user knowingly gave up (edited over, deleted, chose against)
    deleted,    \* deletions a user made: [dev, t]
    lostByRule, \* contents removed by a pulled tombstone newer than them (designed rule)
    rec         \* [Dev -> record]: the device's SyncRecord for the Take (edit stamps)

vars == <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, lock, pc,
          pullSnap, pushPlan, repair, races, resolves, authored, discarded, deleted,
          lostByRule, rec>>

Ver(c, m) == [c |-> c, m |-> m]
V0 == Ver(0, 0)
Held(d) == pair[d] # NoVal
NoRec == [agreed |-> NoVal, uploaded |-> NoVal, shown |-> NoVal, shownLocal |-> NoVal]

-----------------------------------------------------------------------------
Init ==
    \* The Take exists, synced everywhere.
    /\ now = 0
    /\ local = [d \in Dev |-> V0]
    /\ tomb = [d \in Dev |-> NoVal]
    /\ lastSync = [d \in Dev |-> 0]
    /\ pair = [d \in Dev |-> NoVal]
    /\ unv = [d \in Dev |-> NoVal]
    /\ blob = V0
    /\ mEntry = V0
    /\ mTomb = NoVal
    /\ lock = NoVal
    /\ pc = [d \in Dev |-> "idle"]
    /\ pullSnap = [d \in Dev |-> NoVal]
    /\ pushPlan = [d \in Dev |-> NoVal]
    /\ repair = [d \in Dev |-> FALSE]
    /\ races = 0
    /\ resolves = 0
    /\ authored = {0}
    /\ discarded = {}
    /\ deleted = {}
    /\ lostByRule = {}
    \* Synced by a build with records: both agree on V0. (FALSE runs ignore rec.)
    /\ rec = [d \in Dev |-> IF UpgradeStart THEN NoRec ELSE [NoRec EXCEPT !.agreed = 0]]

-----------------------------------------------------------------------------
(* User actions. They may land at any point, including mid-sync.           *)

Edit(d) ==
    /\ now < MaxTime
    /\ local[d] # NoVal
    /\ EditWhileHeld \/ ~Held(d)
    /\ now' = now + 1
    /\ local' = [local EXCEPT ![d] = Ver(now + 1, now + 1)]
    /\ authored' = authored \cup {now + 1}
    /\ discarded' = discarded \cup {local[d].c}
    /\ UNCHANGED <<tomb, lastSync, pair, unv, blob, mEntry, mTomb, lock, pc,
                   pullSnap, pushPlan, repair, races, resolves, deleted, lostByRule, rec>>

\* store.delete: removes the Take and records a tombstone.
Delete(d) ==
    /\ now < MaxTime
    /\ local[d] # NoVal
    /\ EditWhileHeld \/ ~Held(d)
    /\ now' = now + 1
    /\ local' = [local EXCEPT ![d] = NoVal]
    /\ tomb' = [tomb EXCEPT ![d] = now + 1]
    /\ discarded' = discarded \cup {local[d].c}
    /\ deleted' = deleted \cup {[dev |-> d, t |-> now + 1]}
    /\ UNCHANGED <<lastSync, pair, unv, blob, mEntry, mTomb, lock, pc,
                   pullSnap, pushPlan, repair, races, resolves, authored, lostByRule, rec>>

\* ConflictQueue.resolve (Catchlight-iOS): keep this device's version as it is NOW
\* (or the queued copy if it has gone), or the other device's; stamp it as a fresh
\* edit and upsert it, which clears any tombstone.
Resolve(d, keepLocal) ==
    /\ Held(d)
    /\ resolves < MaxResolves
    /\ LET winner == IF keepLocal
                       THEN IF local[d] # NoVal THEN local[d].c ELSE pair[d].l.c
                       ELSE pair[d].r.c
           shown  == IF keepLocal THEN pair[d].r.c ELSE pair[d].l.c
       IN /\ local' = [local EXCEPT ![d] = Ver(winner, now + 1)]
          /\ discarded' = discarded \cup ({shown} \ {winner})
    /\ now' = now + 1
    /\ resolves' = resolves + 1
    /\ tomb' = [tomb EXCEPT ![d] = NoVal]
    /\ pair' = [pair EXCEPT ![d] = NoVal]
    /\ UNCHANGED <<lastSync, unv, blob, mEntry, mTomb, lock, pc, pullSnap, pushPlan,
                   repair, races, authored, deleted, lostByRule, rec>>

\* ConflictQueue.keepPhone: the QUEUED copy of this device's version, stamped fresh.
KeepPhone(d) ==
    /\ unv[d] # NoVal
    /\ ~FixedUnverified \/ local[d] = unv[d].l
    /\ unv[d].l # NoVal
    /\ resolves < MaxResolves
    /\ local' = [local EXCEPT ![d] = Ver(unv[d].l.c, now + 1)]
    /\ discarded' = discarded \cup ({unv[d].r.c} \ {unv[d].l.c})
    /\ now' = now + 1
    /\ resolves' = resolves + 1
    /\ tomb' = [tomb EXCEPT ![d] = NoVal]
    /\ unv' = [unv EXCEPT ![d] = NoVal]
    /\ UNCHANGED <<lastSync, pair, blob, mEntry, mTomb, lock, pc, pullSnap, pushPlan,
                   repair, races, authored, deleted, lostByRule, rec>>

\* With the fix, a stale item is dropped and nothing is written.
DropStaleUnverified(d) ==
    /\ FixedUnverified
    /\ unv[d] # NoVal
    /\ local[d] # unv[d].l
    /\ unv' = [unv EXCEPT ![d] = NoVal]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, blob, mEntry, mTomb, lock, pc, pullSnap,
                   pushPlan, repair, races, resolves, authored, discarded, deleted, lostByRule, rec>>

\* ConflictQueue.keepCloud: the cloud copy that decrypted, stamped fresh.
KeepCloud(d) ==
    /\ unv[d] # NoVal
    /\ ~FixedUnverified \/ local[d] = unv[d].l
    /\ resolves < MaxResolves
    /\ local' = [local EXCEPT ![d] = Ver(unv[d].r.c, now + 1)]
    /\ discarded' = discarded \cup
                    (IF unv[d].l # NoVal THEN {unv[d].l.c} \ {unv[d].r.c} ELSE {})
    /\ now' = now + 1
    /\ resolves' = resolves + 1
    /\ tomb' = [tomb EXCEPT ![d] = NoVal]
    /\ unv' = [unv EXCEPT ![d] = NoVal]
    /\ UNCHANGED <<lastSync, pair, blob, mEntry, mTomb, lock, pc, pullSnap, pushPlan,
                   repair, races, authored, deleted, lostByRule, rec>>

-----------------------------------------------------------------------------
(* store.applyRemote: refused when a live tombstone is at least as new.     *)
ApplyRemote(d, R) ==
    IF tomb[d] # NoVal /\ tomb[d] >= R.m
      THEN /\ UNCHANGED <<local, tomb>>
      ELSE /\ local' = [local EXCEPT ![d] = R]
           /\ tomb' = [tomb EXCEPT ![d] = NoVal]

(* pullInbound, first half: read the manifest, apply its tombstone, purge    *)
(* local tombstones it confirms, and snapshot what the blob read needs.     *)
PullStart(d) ==
    /\ pc[d] = "idle"
    /\ ~SerialSyncs \/ \A e \in Dev : pc[e] = "idle"
    /\ LET L     == local[d]
           T0    == tomb[d]
           doDel == mTomb # NoVal /\ ~Held(d) /\ L # NoVal /\ L.m <= mTomb
       IN /\ local' = [local EXCEPT ![d] = IF doDel THEN NoVal ELSE L]
          \* delete() records a tombstone and the pull purges it at once;
          \* step 2b purges a pending one the manifest confirms.
          /\ tomb' = [tomb EXCEPT ![d] =
                        IF doDel THEN NoVal
                        ELSE IF T0 # NoVal /\ mTomb # NoVal /\ mTomb >= T0 THEN NoVal
                        ELSE T0]
          /\ lostByRule' = IF doDel THEN lostByRule \cup {L.c} ELSE lostByRule
          /\ rec' = IF FixedRecords /\ doDel THEN [rec EXCEPT ![d] = NoRec] ELSE rec
          /\ IF mEntry # NoVal /\ mTomb = NoVal
               THEN /\ pc' = [pc EXCEPT ![d] = "pullBlob"]
                    /\ pullSnap' = [pullSnap EXCEPT ![d] =
                                      [entry |-> mEntry, ls |-> lastSync[d], tsnap |-> T0]]
               ELSE /\ pc' = [pc EXCEPT ![d] = "push"]
                    /\ UNCHANGED pullSnap
    /\ UNCHANGED <<now, lastSync, pair, unv, blob, mEntry, mTomb, lock, pushPlan, repair,
                   races, resolves, authored, discarded, deleted>>

(* refreshRecord, before the blob read: this device's own upload, now in     *)
(* the folder, becomes the agreed version; so does a version shown to the   *)
(* user once the user has settled it (not held, local copy moved or gone).  *)
Refreshed(d, S) ==
    LET r  == rec[d]
        L  == local[d]
        r1 == IF r.uploaded = S.entry.m
                THEN [r EXCEPT !.agreed = S.entry.m, !.uploaded = NoVal] ELSE r
    IN IF r1.shown = S.entry.m /\ ~Held(d) /\ (L = NoVal \/ L.m # r1.shownLocal)
         THEN [r1 EXCEPT !.agreed = S.entry.m, !.shown = NoVal, !.shownLocal = NoVal]
         ELSE r1

Shown(r, E, L) == [r EXCEPT !.shown = E.m, !.shownLocal = IF L = NoVal THEN NoVal ELSE L.m]
Agreed(r, E) == [r EXCEPT !.agreed = E.m, !.uploaded = NoVal]

(* The blob is declared but not readable yet: report.skipped.                *)
PullBlobLag(d) ==
    /\ AllowBlobLag
    /\ pc[d] = "pullBlob"
    /\ pc' = [pc EXCEPT ![d] = "push"]
    /\ rec' = IF FixedRecords THEN [rec EXCEPT ![d] = Refreshed(d, pullSnap[d])] ELSE rec
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, lock,
                   pullSnap, pushPlan, repair, races, resolves, authored, discarded,
                   deleted, lostByRule>>

(* classifyUnverified: the blob's bytes do not match the manifest's HMAC.    *)
Classify(d, S, B) ==
    LET L == local[d]
        r == IF FixedRecords THEN Refreshed(d, S) ELSE rec[d]
        \* With records, a newer local edit is left to push only over a version this
        \* device has agreed with (or with no record, as before).
        newerOk == ~FixedRecords \/ r.agreed = NoVal \/ r.agreed = S.entry.m
    IN
    /\ IF L = NoVal /\ S.tsnap # NoVal
         THEN /\ UNCHANGED <<unv, repair>> /\ rec' = [rec EXCEPT ![d] = r]
       ELSE IF L # NoVal
         THEN IF L.m = S.entry.m
                THEN /\ repair' = [repair EXCEPT ![d] = TRUE]
                     /\ UNCHANGED <<unv>> /\ rec' = [rec EXCEPT ![d] = r]
              ELSE IF L.m > S.entry.m /\ newerOk
                THEN /\ UNCHANGED <<unv, repair>> /\ rec' = [rec EXCEPT ![d] = r]
              ELSE /\ unv' = [unv EXCEPT ![d] = [l |-> L, r |-> B]]
                   /\ UNCHANGED repair
                   /\ rec' = [rec EXCEPT ![d] = IF FixedRecords THEN Shown(r, S.entry, L) ELSE r]
         ELSE /\ unv' = [unv EXCEPT ![d] = [l |-> NoVal, r |-> B]]
              /\ UNCHANGED repair
              /\ rec' = [rec EXCEPT ![d] = IF FixedRecords THEN Shown(r, S.entry, NoVal) ELSE r]
    /\ UNCHANGED <<local, tomb, pair>>

(* The verified path: held check, resurrection guard, ConflictResolver.      *)
Applies(d, R) == ~(tomb[d] # NoVal /\ tomb[d] >= R.m)

MergeOld(d, S, R) ==
    LET L  == local[d]
        lc == L # NoVal /\ L.m > S.ls
        rc == R.m > S.ls
    IN
    /\ IF Held(d) /\ L # NoVal
         THEN /\ IF R.m > S.ls /\ R # L
                   THEN pair' = [pair EXCEPT ![d] = [l |-> L, r |-> R]]
                   ELSE UNCHANGED pair
              /\ UNCHANGED <<local, tomb>>
       ELSE IF L = NoVal /\ S.tsnap # NoVal /\ S.tsnap >= R.m
         THEN UNCHANGED <<local, tomb, pair>>
       ELSE IF L = NoVal
         THEN /\ ApplyRemote(d, R)
              /\ UNCHANGED pair
       ELSE IF L = R
         THEN UNCHANGED <<local, tomb, pair>>
       ELSE IF ~lc /\ rc
         THEN /\ ApplyRemote(d, R)
              /\ UNCHANGED pair
       ELSE IF lc /\ ~rc
         THEN UNCHANGED <<local, tomb, pair>>
       ELSE /\ pair' = [pair EXCEPT ![d] = [l |-> L, r |-> R]]
            /\ UNCHANGED <<local, tomb>>
    /\ UNCHANGED <<unv, repair, rec>>

\* The same with the record (SyncEngine.pullInbound, 2026-11-17).
MergeRec(d, S, R) ==
    LET L  == local[d]
        r  == Refreshed(d, S)
        E  == S.entry
        ownUploadReplaced == L # NoVal /\ L.m = r.uploaded
                             /\ ~(r.shown = E.m /\ r.shownLocal = L.m)
        lc == IF L = NoVal THEN FALSE
              ELSE IF r.agreed # NoVal THEN L.m # r.agreed /\ ~ownUploadReplaced
              ELSE IF r.uploaded # NoVal THEN L.m # r.uploaded
              ELSE L.m > S.ls \/ L.m > R.m
        rc == IF L # NoVal /\ r.agreed # NoVal THEN E.m # r.agreed ELSE TRUE
        unsettled == L # NoVal /\ R # L /\ r.shown = E.m /\ r.shownLocal = L.m
        take == /\ ApplyRemote(d, R)
                /\ UNCHANGED pair
                /\ rec' = [rec EXCEPT ![d] = IF Applies(d, R) THEN Agreed(r, E) ELSE r]
        conflict == /\ pair' = [pair EXCEPT ![d] = [l |-> L, r |-> R]]
                    /\ UNCHANGED <<local, tomb>>
                    /\ rec' = [rec EXCEPT ![d] = Shown(r, E, L)]
    IN
    /\ IF Held(d) /\ L # NoVal
         THEN IF R.m > S.ls /\ R # L
                THEN conflict
                ELSE /\ UNCHANGED <<local, tomb, pair>> /\ rec' = [rec EXCEPT ![d] = r]
       ELSE IF L = NoVal /\ S.tsnap # NoVal /\ S.tsnap >= R.m
         THEN /\ UNCHANGED <<local, tomb, pair>> /\ rec' = [rec EXCEPT ![d] = r]
       ELSE IF L = NoVal
         THEN take
       ELSE IF unsettled
         THEN conflict
       ELSE IF L = R
         THEN /\ UNCHANGED <<local, tomb, pair>> /\ rec' = [rec EXCEPT ![d] = Agreed(r, E)]
       ELSE IF ~lc /\ rc
         THEN take
       ELSE IF lc /\ ~rc
         THEN /\ UNCHANGED <<local, tomb, pair>> /\ rec' = [rec EXCEPT ![d] = r]
       ELSE conflict
    /\ UNCHANGED <<unv, repair>>

Merge(d, S, R) == IF FixedRecords THEN MergeRec(d, S, R) ELSE MergeOld(d, S, R)

PullBlob(d) ==
    /\ pc[d] = "pullBlob"
    /\ LET S == pullSnap[d] IN
       IF blob = NoVal
         THEN /\ UNCHANGED <<local, tomb, pair, unv, repair>>
              /\ rec' = IF FixedRecords THEN [rec EXCEPT ![d] = Refreshed(d, S)] ELSE rec
       ELSE IF blob # S.entry
         THEN Classify(d, S, blob)
       ELSE Merge(d, S, blob)
    /\ pc' = [pc EXCEPT ![d] = "push"]
    /\ UNCHANGED <<now, lastSync, blob, mEntry, mTomb, lock, pullSnap, pushPlan, races,
                   resolves, authored, discarded, deleted, lostByRule>>

-----------------------------------------------------------------------------
(* pushOutbound. The lock is advisory: with cloud propagation delay two      *)
(* devices can both pass it (bounded by MaxRaces). A fresh lock held by      *)
(* another device defers the push (pushDeferred).                            *)

Plan(d) ==
    LET L    == local[d]
        T    == tomb[d]
        ls   == lastSync[d]
        \* The proposed fix: the folder holds a version this device has not seen.
        stale == /\ FixedPushStep1
                 /\ L # NoVal /\ L.m > ls
                 /\ mEntry # NoVal /\ mEntry.m > ls /\ mEntry # L
        held == Held(d) \/ stale
        \* With records: the versions this device has had, and whether the folder's
        \* entry is one it has not had (leaveForNextPull). Every push here follows its
        \* pull, as in sync(), so a Take with no record is guarded too.
        r    == rec[d]
        had  == {r.agreed, r.uploaded} \ {NoVal}
        recordless == r.agreed = NoVal /\ r.uploaded = NoVal
        unseen == /\ FixedRecords
                  /\ L # NoVal /\ mEntry # NoVal /\ mEntry.m # L.m
                  /\ mEntry.m \notin had
        \* step 1: changed since last sync, not held: upload, whatever the entry is
        \* (with records: unless the entry is a version this device has not had)
        up1  == L # NoVal /\ L.m > ls /\ ~held /\ ~unseen
        e1   == IF up1 THEN L ELSE mEntry
        \* step 2: local tombstone: delete the blob, merge the newer record. With
        \* records, a deletion overtaken by a newer version this device has not had
        \* is dropped (edit-wins) instead.
        overtaken == /\ FixedRecords /\ T # NoVal /\ mEntry # NoVal
                     /\ mEntry.m \notin had /\ mEntry.m > T
        Tl   == IF overtaken THEN NoVal ELSE T
        del2 == Tl # NoVal
        t2   == IF Tl # NoVal
                  THEN IF mTomb # NoVal /\ mTomb >= Tl THEN mTomb ELSE Tl
                  ELSE mTomb
        \* step 3: edit-wins, otherwise the tombstone stays and the entry goes
        editWins == t2 # NoVal /\ L # NoVal /\ L.m > t2 /\ ~held
        keepTomb == t2 # NoVal /\ ~editWins
        del3 == keepTomb /\ e1 # NoVal
        e3   == IF keepTomb THEN NoVal ELSE e1
        t3   == IF keepTomb THEN t2 ELSE NoVal
        \* step 4: self-heal: absent, repair, or demonstrably older entry
        up4  == /\ L # NoVal /\ ~keepTomb /\ ~held
                /\ \/ e3 = NoVal
                   \/ repair[d] /\ L.m = e3.m
                   \/ e3.m < L.m /\ ~unseen
        e4   == IF up4 THEN L ELSE e3
        op   == IF up4 THEN "write"
                ELSE IF del2 \/ del3 THEN "delete"
                ELSE IF up1 THEN "write"
                ELSE "none"
        \* step 7: the watermark stays below an edit left for the next pull on a Take
        \* with no record yet
        hold == unseen /\ recordless /\ ~held /\ (L.m > ls \/ ~keepTomb)
        wm   == IF hold THEN IF L.m - 1 > ls THEN IF L.m - 1 < now THEN L.m - 1 ELSE now
                             ELSE ls
                ELSE now
    IN [op |-> op, ver |-> L, entry |-> e4, tomb |-> t3, wm |-> wm, stale |-> stale,
        \* the folder's version this push's deletion record removes (step 3)
        removed |-> IF del3 THEN e1 ELSE NoVal,
        \* step 6: superseded-by-edit purge, and an overtaken deletion
        purge |-> (T # NoVal /\ t3 = NoVal /\ L # NoVal) \/ overtaken]

PushStart(d) ==
    /\ pc[d] = "push"
    /\ \/ /\ lock = NoVal \/ lock = d
          /\ lock' = d
          /\ UNCHANGED races
       \/ /\ lock # NoVal /\ lock # d
          /\ races < MaxRaces
          /\ lock' = d
          /\ races' = races + 1
    /\ pushPlan' = [pushPlan EXCEPT ![d] = Plan(d)]
    /\ pair' = IF Plan(d).stale
                 THEN [pair EXCEPT ![d] = [l |-> local[d], r |-> mEntry]]
                 ELSE pair
    /\ repair' = [repair EXCEPT ![d] = FALSE]
    /\ pc' = [pc EXCEPT ![d] = "pushBlob"]
    /\ UNCHANGED <<now, local, tomb, lastSync, unv, blob, mEntry, mTomb, pullSnap,
                   resolves, authored, discarded, deleted, lostByRule, rec>>

PushDeferred(d) ==
    /\ pc[d] = "push"
    /\ lock # NoVal /\ lock # d
    /\ pc' = [pc EXCEPT ![d] = "idle"]
    /\ repair' = [repair EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, lock,
                   pullSnap, pushPlan, races, resolves, authored, discarded, deleted,
                   lostByRule, rec>>

PushBlob(d) ==
    /\ pc[d] = "pushBlob"
    /\ LET P == pushPlan[d] IN
       blob' = CASE P.op = "write"  -> P.ver
                 \* With records, the file goes only after the manifest drops its entry.
                 [] P.op = "delete" -> IF FixedRecords THEN blob ELSE NoVal
                 [] OTHER           -> blob
    /\ pc' = [pc EXCEPT ![d] = "pushManifest"]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, mEntry, mTomb, lock, pullSnap,
                   pushPlan, repair, races, resolves, authored, discarded, deleted,
                   lostByRule, rec>>

ReleaseLock(d) == IF lock = d THEN NoVal ELSE lock

PushManifest(d) ==
    /\ pc[d] = "pushManifest"
    /\ LET P == pushPlan[d] IN
       /\ mEntry' = P.entry
       /\ mTomb' = P.tomb
       /\ tomb' = [tomb EXCEPT ![d] = IF P.purge THEN NoVal ELSE tomb[d]]
       /\ lastSync' = [lastSync EXCEPT ![d] = P.wm]
       \* A version removed from the folder by a deletion newer than it: the designed
       \* edit-versus-delete rule, as for a pulled deletion record.
       /\ lostByRule' = IF P.removed # NoVal /\ P.tomb # NoVal /\ P.removed.m < P.tomb
                          THEN lostByRule \cup {P.removed.c} ELSE lostByRule
       \* This device's upload, now listed: agreed once a pull sees it there.
       /\ rec' = IF FixedRecords /\ P.op = "write"
                   THEN [rec EXCEPT ![d].uploaded = P.ver.m] ELSE rec
       \* With records: the deleted Take's file, removed after the manifest write,
       \* which is no longer cancellable.
       /\ blob' = IF FixedRecords /\ P.op = "delete" THEN NoVal ELSE blob
    /\ lock' = ReleaseLock(d)
    /\ pc' = [pc EXCEPT ![d] = "idle"]
    /\ UNCHANGED <<now, local, pair, unv, pullSnap, pushPlan, repair, races,
                   resolves, authored, discarded, deleted>>

\* Cancellation (BGTask expiry) before the manifest write; the lock is released.
PushCancel(d) ==
    /\ pc[d] \in {"pushBlob", "pushManifest"}
    /\ lock' = ReleaseLock(d)
    /\ pc' = [pc EXCEPT ![d] = "idle"]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, pullSnap,
                   pushPlan, repair, races, resolves, authored, discarded, deleted,
                   lostByRule, rec>>

-----------------------------------------------------------------------------
SyncStep(d) ==
    \/ PullStart(d) \/ PullBlob(d) \/ PullBlobLag(d)
    \/ PushStart(d) \/ PushDeferred(d) \/ PushBlob(d) \/ PushManifest(d)

UserStep(d) ==
    \/ Edit(d) \/ Delete(d)
    \/ Resolve(d, TRUE) \/ Resolve(d, FALSE)
    \/ KeepPhone(d) \/ KeepCloud(d) \/ DropStaleUnverified(d)

Next == \E d \in Dev : SyncStep(d) \/ UserStep(d) \/ PushCancel(d)

\* For the convergence check: syncing keeps happening, a push that keeps getting the
\* chance to finish eventually does (cancellation and lock deferral are not forever),
\* and the user eventually answers every conflict (while choices remain).
Fairness == \A d \in Dev :
    /\ SF_vars(SyncStep(d))
    /\ SF_vars(PushStart(d)) /\ SF_vars(PushBlob(d)) /\ SF_vars(PushManifest(d))
    /\ WF_vars(Resolve(d, TRUE) \/ KeepPhone(d) \/ KeepCloud(d) \/ DropStaleUnverified(d))

Spec == Init /\ [][Next]_vars
LiveSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* What a user cares about.                                                 *)

\* Where a user could still find a content: a device's store, a queue the app
\* shows, or the folder's copy while the manifest lists the Take.
Alive ==
    {local[d].c : d \in {e \in Dev : local[e] # NoVal}}
    \cup {pair[d].l.c : d \in {e \in Dev : pair[e] # NoVal}}
    \cup {pair[d].r.c : d \in {e \in Dev : pair[e] # NoVal}}
    \cup {unv[d].r.c : d \in {e \in Dev : unv[e] # NoVal}}
    \cup {unv[d].l.c : d \in {e \in Dev : unv[e] # NoVal /\ unv[e].l # NoVal}}
    \cup (IF mEntry # NoVal /\ blob # NoVal THEN {blob.c} ELSE {})

\* No edit is ever lost unless a user gave it up, or a newer deletion removed it
\* (the designed edit-versus-delete rule: the later timestamp wins).
NoSilentLoss == authored \subseteq (Alive \cup discarded \cup lostByRule)

\* The same without the designed rule's exemption. Expected to fail: it shows
\* the model can find a loss, and the trace shows the rule at work.
NoSilentLossStrict == authored \subseteq (Alive \cup discarded)

\* Sync never brings back a version that a deletion supersedes: a version arriving
\* on a device is newer than every deletion that device made, and newer than the
\* folder's deletion record. (A user's own choice is stamped fresh, so it passes.)
NoResurrection ==
    [][\A d \in Dev :
         (local'[d] # NoVal /\ local'[d] # local[d])
            => /\ \A x \in deleted : x.dev = d => local'[d].m > x.t
               /\ mTomb # NoVal => local'[d].m > mTomb]_vars

\* Every device holds the same version as the folder, with nothing waiting.
Converged ==
    /\ \A d \in Dev :
         /\ pair[d] = NoVal /\ unv[d] = NoVal
         /\ IF local[d] = NoVal
              THEN mEntry = NoVal
              ELSE mEntry = local[d] /\ blob = local[d]
    /\ \A d, e \in Dev : local[d] = local[e]

EventuallyConverges == <>[]Converged

TypeOK ==
    /\ now \in 0..(MaxTime + MaxResolves)
    /\ pc \in [Dev -> {"idle", "pullBlob", "push", "pushBlob", "pushManifest"}]
    /\ lock \in Dev \cup {NoVal}
=============================================================================
