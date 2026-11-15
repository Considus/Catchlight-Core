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
    EditWhileHeld   \* TRUE: the user may edit a Take waiting in the conflict queue

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
    deleted,    \* contents a user deleted
    lostByRule  \* contents removed by a pulled tombstone newer than them (designed rule)

vars == <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, lock, pc,
          pullSnap, pushPlan, repair, races, resolves, authored, discarded, deleted,
          lostByRule>>

Ver(c, m) == [c |-> c, m |-> m]
V0 == Ver(0, 0)
Held(d) == pair[d] # NoVal

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
                   pullSnap, pushPlan, repair, races, resolves, deleted, lostByRule>>

\* store.delete: removes the Take and records a tombstone.
Delete(d) ==
    /\ now < MaxTime
    /\ local[d] # NoVal
    /\ EditWhileHeld \/ ~Held(d)
    /\ now' = now + 1
    /\ local' = [local EXCEPT ![d] = NoVal]
    /\ tomb' = [tomb EXCEPT ![d] = now + 1]
    /\ discarded' = discarded \cup {local[d].c}
    /\ deleted' = deleted \cup {local[d].c}
    /\ UNCHANGED <<lastSync, pair, unv, blob, mEntry, mTomb, lock, pc,
                   pullSnap, pushPlan, repair, races, resolves, authored, lostByRule>>

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
                   repair, races, authored, deleted, lostByRule>>

\* ConflictQueue.keepPhone: the QUEUED copy of this device's version, stamped fresh.
KeepPhone(d) ==
    /\ unv[d] # NoVal
    /\ unv[d].l # NoVal
    /\ resolves < MaxResolves
    /\ local' = [local EXCEPT ![d] = Ver(unv[d].l.c, now + 1)]
    /\ discarded' = discarded \cup ({unv[d].r.c} \ {unv[d].l.c})
    /\ now' = now + 1
    /\ resolves' = resolves + 1
    /\ tomb' = [tomb EXCEPT ![d] = NoVal]
    /\ unv' = [unv EXCEPT ![d] = NoVal]
    /\ UNCHANGED <<lastSync, pair, blob, mEntry, mTomb, lock, pc, pullSnap, pushPlan,
                   repair, races, authored, deleted, lostByRule>>

\* ConflictQueue.keepCloud: the cloud copy that decrypted, stamped fresh.
KeepCloud(d) ==
    /\ unv[d] # NoVal
    /\ resolves < MaxResolves
    /\ local' = [local EXCEPT ![d] = Ver(unv[d].r.c, now + 1)]
    /\ discarded' = discarded \cup
                    (IF unv[d].l # NoVal THEN {unv[d].l.c} \ {unv[d].r.c} ELSE {})
    /\ now' = now + 1
    /\ resolves' = resolves + 1
    /\ tomb' = [tomb EXCEPT ![d] = NoVal]
    /\ unv' = [unv EXCEPT ![d] = NoVal]
    /\ UNCHANGED <<lastSync, pair, blob, mEntry, mTomb, lock, pc, pullSnap, pushPlan,
                   repair, races, authored, deleted, lostByRule>>

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
          /\ IF mEntry # NoVal /\ mTomb = NoVal
               THEN /\ pc' = [pc EXCEPT ![d] = "pullBlob"]
                    /\ pullSnap' = [pullSnap EXCEPT ![d] =
                                      [entry |-> mEntry, ls |-> lastSync[d], tsnap |-> T0]]
               ELSE /\ pc' = [pc EXCEPT ![d] = "push"]
                    /\ UNCHANGED pullSnap
    /\ UNCHANGED <<now, lastSync, pair, unv, blob, mEntry, mTomb, lock, pushPlan, repair,
                   races, resolves, authored, discarded, deleted>>

(* The blob is declared but not readable yet: report.skipped.                *)
PullBlobLag(d) ==
    /\ AllowBlobLag
    /\ pc[d] = "pullBlob"
    /\ pc' = [pc EXCEPT ![d] = "push"]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, lock,
                   pullSnap, pushPlan, repair, races, resolves, authored, discarded,
                   deleted, lostByRule>>

(* classifyUnverified: the blob's bytes do not match the manifest's HMAC.    *)
Classify(d, S, B) ==
    LET L == local[d] IN
    /\ IF L = NoVal /\ S.tsnap # NoVal THEN UNCHANGED <<unv, repair>>
       ELSE IF L # NoVal
         THEN IF L.m = S.entry.m
                THEN /\ repair' = [repair EXCEPT ![d] = TRUE]
                     /\ UNCHANGED unv
              ELSE IF L.m > S.entry.m THEN UNCHANGED <<unv, repair>>
              ELSE /\ unv' = [unv EXCEPT ![d] = [l |-> L, r |-> B]]
                   /\ UNCHANGED repair
         ELSE /\ unv' = [unv EXCEPT ![d] = [l |-> NoVal, r |-> B]]
              /\ UNCHANGED repair
    /\ UNCHANGED <<local, tomb, pair>>

(* The verified path: held check, resurrection guard, ConflictResolver.      *)
Merge(d, S, R) ==
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
    /\ UNCHANGED <<unv, repair>>

PullBlob(d) ==
    /\ pc[d] = "pullBlob"
    /\ LET S == pullSnap[d] IN
       IF blob = NoVal
         THEN UNCHANGED <<local, tomb, pair, unv, repair>>
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
        held == Held(d)
        \* step 1: changed since last sync, not held: upload, whatever the entry is
        up1  == L # NoVal /\ L.m > ls /\ ~held
        e1   == IF up1 THEN L ELSE mEntry
        \* step 2: local tombstone: delete the blob, merge the newer record
        del2 == T # NoVal
        t2   == IF T # NoVal
                  THEN IF mTomb # NoVal /\ mTomb >= T THEN mTomb ELSE T
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
                   \/ e3.m < L.m
        e4   == IF up4 THEN L ELSE e3
        op   == IF up4 THEN "write"
                ELSE IF del2 \/ del3 THEN "delete"
                ELSE IF up1 THEN "write"
                ELSE "none"
    IN [op |-> op, ver |-> L, entry |-> e4, tomb |-> t3, wm |-> now,
        \* step 6: superseded-by-edit purge
        purge |-> (T # NoVal /\ t3 = NoVal /\ L # NoVal)]

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
    /\ repair' = [repair EXCEPT ![d] = FALSE]
    /\ pc' = [pc EXCEPT ![d] = "pushBlob"]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, pullSnap,
                   resolves, authored, discarded, deleted, lostByRule>>

PushDeferred(d) ==
    /\ pc[d] = "push"
    /\ lock # NoVal /\ lock # d
    /\ pc' = [pc EXCEPT ![d] = "idle"]
    /\ repair' = [repair EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, lock,
                   pullSnap, pushPlan, races, resolves, authored, discarded, deleted,
                   lostByRule>>

PushBlob(d) ==
    /\ pc[d] = "pushBlob"
    /\ LET P == pushPlan[d] IN
       blob' = CASE P.op = "write"  -> P.ver
                 [] P.op = "delete" -> NoVal
                 [] OTHER           -> blob
    /\ pc' = [pc EXCEPT ![d] = "pushManifest"]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, mEntry, mTomb, lock, pullSnap,
                   pushPlan, repair, races, resolves, authored, discarded, deleted,
                   lostByRule>>

ReleaseLock(d) == IF lock = d THEN NoVal ELSE lock

PushManifest(d) ==
    /\ pc[d] = "pushManifest"
    /\ LET P == pushPlan[d] IN
       /\ mEntry' = P.entry
       /\ mTomb' = P.tomb
       /\ tomb' = [tomb EXCEPT ![d] = IF P.purge THEN NoVal ELSE tomb[d]]
       /\ lastSync' = [lastSync EXCEPT ![d] = P.wm]
    /\ lock' = ReleaseLock(d)
    /\ pc' = [pc EXCEPT ![d] = "idle"]
    /\ UNCHANGED <<now, local, pair, unv, blob, pullSnap, pushPlan, repair, races,
                   resolves, authored, discarded, deleted, lostByRule>>

\* Cancellation (BGTask expiry) before the manifest write; the lock is released.
PushCancel(d) ==
    /\ pc[d] \in {"pushBlob", "pushManifest"}
    /\ lock' = ReleaseLock(d)
    /\ pc' = [pc EXCEPT ![d] = "idle"]
    /\ UNCHANGED <<now, local, tomb, lastSync, pair, unv, blob, mEntry, mTomb, pullSnap,
                   pushPlan, repair, races, resolves, authored, discarded, deleted,
                   lostByRule>>

-----------------------------------------------------------------------------
SyncStep(d) ==
    \/ PullStart(d) \/ PullBlob(d) \/ PullBlobLag(d)
    \/ PushStart(d) \/ PushDeferred(d) \/ PushBlob(d) \/ PushManifest(d)

UserStep(d) ==
    \/ Edit(d) \/ Delete(d)
    \/ Resolve(d, TRUE) \/ Resolve(d, FALSE)
    \/ KeepPhone(d) \/ KeepCloud(d)

Next == \E d \in Dev : SyncStep(d) \/ UserStep(d) \/ PushCancel(d)

\* For the convergence check: syncing keeps happening, and the user eventually
\* answers every conflict (while choices remain).
Fairness == \A d \in Dev :
    /\ WF_vars(SyncStep(d))
    /\ WF_vars(Resolve(d, TRUE) \/ KeepPhone(d) \/ KeepCloud(d))

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

\* A deleted content never arrives on a device that did not already hold it.
NoResurrection ==
    [][\A d \in Dev :
         (local'[d] # NoVal /\ local'[d].c \in deleted)
            => (local[d] # NoVal /\ local[d].c = local'[d].c)]_vars

\* Every device holds the same version as the folder, with nothing waiting.
Converged ==
    /\ \A d \in Dev :
         /\ pair[d] = NoVal /\ unv[d] = NoVal /\ pc[d] = "idle"
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
