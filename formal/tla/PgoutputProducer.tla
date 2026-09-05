------------------------ MODULE PgoutputProducer ------------------------
EXTENDS Naturals

\* This model selects the transaction-ordering semantics implemented by
\* Flyology.Postgres.Replication.Logical.Producer.Emit.  One model action is
\* one atomic Emit call.  Two transaction identities and two segments per
\* identity are TLC qualification geometry, not product capacities.
\*
\* The model includes regular transactions, streamed segments, stream
\* completion and abort, xid-bearing data, and logical decoding messages.
\* It abstracts encoded bytes to the presence and value of the streamed xid
\* prefix.  Allocation, transport, cancellation, crashes, retries, exact
\* payload bytes, and the separately retained monotonic WAL-envelope contract
\* are outside this model.
\*
\* No fairness or liveness assumption is needed: Producer is a synchronous
\* validator driven by its caller.  TLC checks bounded safety and reachability;
\* PgoutputProducerProof proves the smaller unbounded safety kernel; executable
\* tests check exact codecs; and the shared Flyology TLA harness replays a
\* deterministic TLC trace through the Ada implementation.

CONSTANTS BugMode, Scenario

Xids == {"T1", "T2"}
OptionalXids == Xids \cup {"None"}
Contexts == {"Idle", "Regular", "Segment", "Paused"}
Actions ==
  {"Init", "BeginRegular", "CommitRegular", "StartStream", "StopStream",
   "CommitStream", "AbortStream", "Data", "LogicalMessage"}

VARIABLES
  context, currentXid,
  pausedT1, pausedT2, recentPaused,
  segmentsT1, segmentsT2, scenarioStep,
  lastAction, lastXid, lastSubxid, lastFirst, lastTransactional,
  lastOutcome, lastHasPrefix, lastWireXid

vars ==
  <<context, currentXid,
    pausedT1, pausedT2, recentPaused,
    segmentsT1, segmentsT2, scenarioStep,
    lastAction, lastXid, lastSubxid, lastFirst, lastTransactional,
    lastOutcome, lastHasPrefix, lastWireXid>>

Core ==
  [context      |-> context,
   currentXid   |-> currentXid,
   pausedT1     |-> pausedT1,
   pausedT2     |-> pausedT2,
   recentPaused |-> recentPaused,
   segmentsT1   |-> segmentsT1,
   segmentsT2   |-> segmentsT2]

IsPaused(s, xid) ==
  CASE xid = "T1" -> s.pausedT1
    [] xid = "T2" -> s.pausedT2
    [] OTHER       -> FALSE

SegmentCount(s, xid) ==
  IF xid = "T1" THEN s.segmentsT1 ELSE s.segmentsT2

Inactive(s) == s.context \in {"Idle", "Paused"}

FallbackXid(s) ==
  IF s.recentPaused \in Xids /\ IsPaused(s, s.recentPaused)
  THEN s.recentPaused
  ELSE IF s.pausedT1 THEN "T1"
  ELSE IF s.pausedT2 THEN "T2"
  ELSE "None"

FallbackContext(s) ==
  IF s.pausedT1 \/ s.pausedT2 THEN "Paused" ELSE "Idle"

SetPaused(s, xid, value) ==
  IF xid = "T1"
  THEN [s EXCEPT !.pausedT1 = value]
  ELSE [s EXCEPT !.pausedT2 = value]

NormalizeRecent(s) ==
  IF s.pausedT1 \/ s.pausedT2
  THEN IF s.recentPaused \in Xids /\ IsPaused(s, s.recentPaused)
       THEN s
       ELSE [s EXCEPT !.recentPaused =
              IF s.pausedT1 THEN "T1" ELSE "T2"]
  ELSE [s EXCEPT !.recentPaused = "None"]

BeginState(s, xid) ==
  [s EXCEPT !.context = "Regular", !.currentXid = xid]

FinishActiveState(s) ==
  [s EXCEPT
     !.context = FallbackContext(s),
     !.currentXid = FallbackXid(s)]

StartState(s, xid) ==
  LET removed == NormalizeRecent(SetPaused(s, xid, FALSE))
  IN IF xid = "T1"
     THEN [removed EXCEPT
            !.context = "Segment", !.currentXid = xid,
            !.segmentsT1 = @ + 1]
     ELSE [removed EXCEPT
            !.context = "Segment", !.currentXid = xid,
            !.segmentsT2 = @ + 1]

StopState(s) ==
  LET paused == SetPaused(s, s.currentXid, TRUE)
  IN [paused EXCEPT
       !.context = "Paused",
       !.currentXid = s.currentXid,
       !.recentPaused = s.currentXid]

FinishStreamState(s, xid) ==
  LET removed == NormalizeRecent(SetPaused(s, xid, FALSE))
  IN [removed EXCEPT
       !.context = FallbackContext(removed),
       !.currentXid = FallbackXid(removed)]

PreserveAfterSubabort(s, xid) ==
  [s EXCEPT
     !.context = "Paused", !.currentXid = xid, !.recentPaused = xid]

ApprovedAccepts(s, kind, xid, subxid, first, transactional) ==
  CASE kind = "BeginRegular" ->
         Inactive(s) /\ xid \in Xids /\ ~IsPaused(s, xid)
    [] kind = "CommitRegular" -> s.context = "Regular"
    [] kind = "StartStream" ->
         /\ Inactive(s)
         /\ xid \in Xids
         /\ SegmentCount(s, xid) < 2
         /\ IF first THEN ~IsPaused(s, xid) ELSE IsPaused(s, xid)
    [] kind = "StopStream" -> s.context = "Segment"
    [] kind = "CommitStream" -> Inactive(s) /\ IsPaused(s, xid)
    [] kind = "AbortStream" ->
         Inactive(s) /\ IsPaused(s, xid) /\ subxid \in Xids
    [] kind = "Data" ->
         IF s.context = "Segment"
         THEN xid = s.currentXid
         ELSE s.context = "Regular" /\ xid = "None"
    [] kind = "LogicalMessage" ->
         IF transactional
         THEN IF s.context = "Segment"
              THEN xid = s.currentXid
              ELSE s.context = "Regular" /\ xid = "None"
         ELSE Inactive(s) /\ xid = "None"
    [] OTHER -> FALSE

Issue56Accepts(s, kind, xid, subxid, first, transactional) ==
  IF kind \in {"Data", "LogicalMessage"}
     /\ (kind = "Data" \/ transactional)
     /\ s.context = "Segment"
     /\ xid = "None"
  THEN TRUE
  ELSE ApprovedAccepts(s, kind, xid, subxid, first, transactional)

Issue57Accepts(s, kind, xid, subxid, first, transactional) ==
  CASE kind = "BeginRegular" -> s.context = "Idle" /\ xid \in Xids
    [] kind = "StartStream" ->
         /\ xid \in Xids
         /\ SegmentCount(s, xid) < 2
         /\ IF first
               THEN s.context = "Idle"
               ELSE s.context = "Paused" /\ s.currentXid = xid
    [] kind \in {"CommitStream", "AbortStream"} ->
         s.context = "Paused" /\ s.currentXid = xid
    [] OTHER ->
         ApprovedAccepts(s, kind, xid, subxid, first, transactional)

Issue58Accepts(s, kind, xid, subxid, first, transactional) ==
  IF kind = "LogicalMessage" /\ ~transactional
  THEN /\ s.context \in {"Regular", "Segment"}
       /\ IF xid = "None"
             THEN TRUE
             ELSE s.context = "Segment" /\ xid = s.currentXid
  ELSE ApprovedAccepts(s, kind, xid, subxid, first, transactional)

ActualAccepts(s, kind, xid, subxid, first, transactional) ==
  CASE BugMode = "Issue56" ->
         Issue56Accepts(s, kind, xid, subxid, first, transactional)
    [] BugMode = "Issue57" ->
         Issue57Accepts(s, kind, xid, subxid, first, transactional)
    [] BugMode = "Issue58" ->
         Issue58Accepts(s, kind, xid, subxid, first, transactional)
    [] OTHER -> ApprovedAccepts(s, kind, xid, subxid, first, transactional)

ApprovedTransition(s, kind, xid, subxid) ==
  CASE kind = "BeginRegular" -> BeginState(s, xid)
    [] kind = "CommitRegular" -> FinishActiveState(s)
    [] kind = "StartStream" -> StartState(s, xid)
    [] kind = "StopStream" -> StopState(s)
    [] kind = "CommitStream" -> FinishStreamState(s, xid)
    [] kind = "AbortStream" ->
         IF xid = subxid
         THEN FinishStreamState(s, xid)
         ELSE PreserveAfterSubabort(s, xid)
    [] OTHER -> s

ActualTransition(s, kind, xid, subxid) ==
  IF BugMode = "Issue57" /\ kind = "AbortStream"
  THEN FinishStreamState(s, xid)
  ELSE ApprovedTransition(s, kind, xid, subxid)

Attempt(kind, xid, subxid, first, transactional) ==
  LET accepted ==
        ActualAccepts(Core, kind, xid, subxid, first, transactional)
      nextCore ==
        IF accepted
        THEN ActualTransition(Core, kind, xid, subxid)
        ELSE Core
      prefix == accepted /\ kind \in {"Data", "LogicalMessage"}
                  /\ xid \in Xids
  IN
    /\ context' = nextCore.context
    /\ currentXid' = nextCore.currentXid
    /\ pausedT1' = nextCore.pausedT1
    /\ pausedT2' = nextCore.pausedT2
    /\ recentPaused' = nextCore.recentPaused
    /\ segmentsT1' = nextCore.segmentsT1
    /\ segmentsT2' = nextCore.segmentsT2
    /\ scenarioStep' = IF Scenario = "Explore" THEN 0 ELSE scenarioStep + 1
    /\ lastAction' = kind
    /\ lastXid' = xid
    /\ lastSubxid' = subxid
    /\ lastFirst' = first
    /\ lastTransactional' = transactional
    /\ lastOutcome' = accepted
    /\ lastHasPrefix' = prefix
    /\ lastWireXid' = IF prefix THEN xid ELSE "None"

BeginRegular(xid) ==
  Attempt("BeginRegular", xid, "None", FALSE, FALSE)

CommitRegular ==
  Attempt("CommitRegular", "None", "None", FALSE, FALSE)

StartStream(xid, first) ==
  Attempt("StartStream", xid, "None", first, FALSE)

StopStream ==
  Attempt("StopStream", "None", "None", FALSE, FALSE)

CommitStream(xid) ==
  Attempt("CommitStream", xid, "None", FALSE, FALSE)

AbortStream(xid, subxid) ==
  Attempt("AbortStream", xid, subxid, FALSE, FALSE)

EmitData(xid) ==
  Attempt("Data", xid, "None", FALSE, FALSE)

EmitLogicalMessage(xid, transactional) ==
  Attempt("LogicalMessage", xid, "None", FALSE, transactional)

ExploreNext ==
  \/ \E xid \in Xids : BeginRegular(xid)
  \/ CommitRegular
  \/ \E xid \in Xids, first \in BOOLEAN : StartStream(xid, first)
  \/ StopStream
  \/ \E xid \in Xids : CommitStream(xid)
  \/ \E xid \in Xids, subxid \in Xids : AbortStream(xid, subxid)
  \/ \E xid \in OptionalXids : EmitData(xid)
  \/ \E xid \in OptionalXids, transactional \in BOOLEAN :
       EmitLogicalMessage(xid, transactional)

Issue56Next ==
  CASE scenarioStep = 0 -> StartStream("T1", TRUE)
    [] scenarioStep = 1 -> EmitData("None")
    [] OTHER -> FALSE

Issue57Next ==
  CASE scenarioStep = 0 -> StartStream("T1", TRUE)
    [] scenarioStep = 1 -> StopStream
    [] scenarioStep = 2 -> AbortStream("T1", "T2")
    [] OTHER -> FALSE

Issue58Next ==
  CASE scenarioStep = 0 -> EmitLogicalMessage("None", FALSE)
    [] OTHER -> FALSE

ReplayNext ==
  CASE scenarioStep = 0  -> StartStream("T1", TRUE)
    [] scenarioStep = 1  -> EmitData("None")
    [] scenarioStep = 2  -> EmitLogicalMessage("None", TRUE)
    [] scenarioStep = 3  -> EmitData("T1")
    [] scenarioStep = 4  -> StopStream
    [] scenarioStep = 5  -> AbortStream("T1", "T2")
    [] scenarioStep = 6  -> StartStream("T1", FALSE)
    [] scenarioStep = 7  -> StopStream
    [] scenarioStep = 8  -> BeginRegular("T2")
    [] scenarioStep = 9  -> EmitData("None")
    [] scenarioStep = 10 -> CommitRegular
    [] scenarioStep = 11 -> StartStream("T2", TRUE)
    [] scenarioStep = 12 -> EmitData("T2")
    [] scenarioStep = 13 -> StopStream
    [] scenarioStep = 14 -> EmitLogicalMessage("None", FALSE)
    [] scenarioStep = 15 -> CommitStream("T2")
    [] scenarioStep = 16 -> CommitStream("T1")
    [] scenarioStep = 17 -> EmitLogicalMessage("None", TRUE)
    [] scenarioStep = 18 -> EmitLogicalMessage("None", FALSE)
    [] OTHER -> FALSE

Next ==
  CASE Scenario = "Explore" -> ExploreNext
    [] Scenario = "Issue56" -> Issue56Next
    [] Scenario = "Issue57" -> Issue57Next
    [] Scenario = "Issue58" -> Issue58Next
    [] Scenario = "Replay"  -> ReplayNext
    [] OTHER -> FALSE

Init ==
  /\ context = "Idle"
  /\ currentXid = "None"
  /\ pausedT1 = FALSE
  /\ pausedT2 = FALSE
  /\ recentPaused = "None"
  /\ segmentsT1 = 0
  /\ segmentsT2 = 0
  /\ scenarioStep = 0
  /\ lastAction = "Init"
  /\ lastXid = "None"
  /\ lastSubxid = "None"
  /\ lastFirst = FALSE
  /\ lastTransactional = FALSE
  /\ lastOutcome = TRUE
  /\ lastHasPrefix = FALSE
  /\ lastWireXid = "None"

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ context \in {"Idle", "Regular", "Segment", "Paused"}
  /\ currentXid \in {"None", "T1", "T2"}
  /\ pausedT1 \in BOOLEAN
  /\ pausedT2 \in BOOLEAN
  /\ recentPaused \in {"None", "T1", "T2"}
  /\ segmentsT1 \in 0..2
  /\ segmentsT2 \in 0..2
  /\ scenarioStep \in 0..19
  /\ lastAction \in
       {"Init", "BeginRegular", "CommitRegular", "StartStream",
        "StopStream", "CommitStream", "AbortStream", "Data",
        "LogicalMessage"}
  /\ lastXid \in {"None", "T1", "T2"}
  /\ lastSubxid \in {"None", "T1", "T2"}
  /\ lastFirst \in BOOLEAN
  /\ lastTransactional \in BOOLEAN
  /\ lastOutcome \in BOOLEAN
  /\ lastHasPrefix \in BOOLEAN
  /\ lastWireXid \in {"None", "T1", "T2"}

RecentPausedConsistent ==
  /\ (recentPaused = "None") = (~pausedT1 /\ ~pausedT2)
  /\ (recentPaused = "T1" => pausedT1)
  /\ (recentPaused = "T2" => pausedT2)

ContextConsistent ==
  /\ (context = "Idle") =
       (currentXid = "None" /\ ~pausedT1 /\ ~pausedT2)
  /\ (context = "Paused") =>
       (currentXid = recentPaused /\ currentXid \in Xids)
  /\ (context \in {"Regular", "Segment"}) =>
       (currentXid \in Xids /\ ~IsPaused(Core, currentXid))

RelevantOutcomeSafe ==
  CASE lastAction = "Data" ->
         IF context = "Segment"
         THEN lastOutcome = (lastXid = currentXid)
         ELSE IF context = "Regular"
         THEN lastOutcome = (lastXid = "None")
         ELSE ~lastOutcome
    [] lastAction = "LogicalMessage" ->
         IF lastTransactional
         THEN IF context = "Segment"
              THEN lastOutcome = (lastXid = currentXid)
              ELSE IF context = "Regular"
              THEN lastOutcome = (lastXid = "None")
              ELSE ~lastOutcome
         ELSE lastOutcome =
                (context \in {"Idle", "Paused"} /\ lastXid = "None")
    [] OTHER -> TRUE

SegmentPrefixSafe ==
  lastOutcome /\ context = "Segment"
    /\ lastAction \in {"Data", "LogicalMessage"}
    => lastHasPrefix /\ lastWireXid = currentXid

SubabortPreservesTop ==
  lastOutcome /\ lastAction = "AbortStream"
    /\ lastXid /= lastSubxid
    => IsPaused(Core, lastXid)

WitnessPending == Scenario /= "Replay" \/ scenarioStep < 19

InputKind == IF lastAction = "Init" THEN "Data" ELSE lastAction

HarnessInputType ==
  [kind          : {"BeginRegular", "CommitRegular", "StartStream",
                    "StopStream", "CommitStream", "AbortStream", "Data",
                    "LogicalMessage"},
   xid           : {"None", "T1", "T2"},
   subxid        : {"None", "T1", "T2"},
   firstSegment  : BOOLEAN,
   transactional : BOOLEAN]

HarnessOutcomeType ==
  [accepted  : BOOLEAN,
   hasPrefix : BOOLEAN,
   wireXid   : {"None", "T1", "T2"}]

StateProjection ==
  [context           |-> context,
   currentXid        |-> currentXid,
   pausedT1          |-> pausedT1,
   pausedT2          |-> pausedT2,
   recentPaused      |-> recentPaused,
   segmentsT1        |-> segmentsT1,
   segmentsT2        |-> segmentsT2,
   scenarioStep      |-> scenarioStep,
   lastAction        |-> lastAction,
   lastXid           |-> lastXid,
   lastSubxid        |-> lastSubxid,
   lastFirst         |-> lastFirst,
   lastTransactional |-> lastTransactional,
   lastOutcome       |-> lastOutcome,
   lastHasPrefix     |-> lastHasPrefix,
   lastWireXid       |-> lastWireXid]

Alias ==
  [action |-> lastAction,
   role |-> "pgoutput-producer",
   input |->
     [kind          |-> InputKind,
      xid           |-> lastXid,
      subxid        |-> lastSubxid,
      firstSegment  |-> lastFirst,
      transactional |-> lastTransactional],
   outcome |->
     [accepted  |-> lastOutcome,
      hasPrefix |-> lastHasPrefix,
      wireXid   |-> lastWireXid],
   state |-> StateProjection,
   model_source |-> lastAction]

=============================================================================
