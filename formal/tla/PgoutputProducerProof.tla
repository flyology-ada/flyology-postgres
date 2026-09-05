---------------------- MODULE PgoutputProducerProof ----------------------
EXTENDS Naturals

\* Unbounded safety kernel for the pgoutput Producer ordering contract.
\* TX is arbitrary: unlike the TLC model, this proof has no transaction or
\* segment-count bound.  It proves only the safety facts used by #56--#58;
\* reachability of representative interleavings is checked by TLC and replay.

CONSTANTS TX, None

DomainOK == TX /= {} /\ None \notin TX

VARIABLES context, current, paused,
          emittedInSegment, emittedHasPrefix, emittedXid,
          emittedNontransactional,
          subabort, abortTop, abortSub

vars ==
  <<context, current, paused,
    emittedInSegment, emittedHasPrefix, emittedXid,
    emittedNontransactional,
    subabort, abortTop, abortSub>>

TypeOK ==
  /\ context \in {"Idle", "Regular", "Segment", "Paused"}
  /\ current \in TX \cup {None}
  /\ paused \subseteq TX
  /\ emittedInSegment \in BOOLEAN
  /\ emittedHasPrefix \in BOOLEAN
  /\ emittedXid \in TX \cup {None}
  /\ emittedNontransactional \in BOOLEAN
  /\ subabort \in BOOLEAN
  /\ abortTop \in TX \cup {None}
  /\ abortSub \in TX \cup {None}

ContextOK ==
  /\ (context = "Idle") = (current = None /\ paused = {})
  /\ (context = "Paused") => (current \in paused)
  /\ (context \in {"Regular", "Segment"}) =>
       (current \in TX /\ current \notin paused)

SegmentPrefixOK ==
  emittedInSegment => emittedHasPrefix /\ emittedXid = current

NontransactionalOK ==
  emittedNontransactional => context \in {"Idle", "Paused"}

SubabortOK ==
  subabort /\ abortTop /= abortSub => abortTop \in paused

Inv ==
  TypeOK /\ ContextOK /\ SegmentPrefixOK /\ NontransactionalOK /\ SubabortOK

Init ==
  /\ context = "Idle"
  /\ current = None
  /\ paused = {}
  /\ emittedInSegment = FALSE
  /\ emittedHasPrefix = FALSE
  /\ emittedXid = None
  /\ emittedNontransactional = FALSE
  /\ subabort = FALSE
  /\ abortTop = None
  /\ abortSub = None

ClearObservations ==
  /\ emittedInSegment' = FALSE
  /\ emittedHasPrefix' = FALSE
  /\ emittedXid' = None
  /\ emittedNontransactional' = FALSE
  /\ subabort' = FALSE
  /\ abortTop' = None
  /\ abortSub' = None

BeginRegular(xid) ==
  /\ context \in {"Idle", "Paused"}
  /\ xid \in TX \ paused
  /\ context' = "Regular"
  /\ current' = xid
  /\ UNCHANGED paused
  /\ ClearObservations

CommitRegular(fallback) ==
  /\ context = "Regular"
  /\ fallback \in paused \cup {None}
  /\ (paused = {} => fallback = None)
  /\ (paused /= {} => fallback \in paused)
  /\ context' = IF paused = {} THEN "Idle" ELSE "Paused"
  /\ current' = fallback
  /\ UNCHANGED paused
  /\ ClearObservations

StartStream(xid) ==
  /\ context \in {"Idle", "Paused"}
  /\ xid \in TX
  /\ context' = "Segment"
  /\ current' = xid
  /\ paused' = paused \ {xid}
  /\ ClearObservations

StopStream ==
  /\ context = "Segment"
  /\ context' = "Paused"
  /\ current' = current
  /\ paused' = paused \cup {current}
  /\ ClearObservations

FinishStream(xid, fallback) ==
  /\ context = "Paused"
  /\ xid \in paused
  /\ fallback \in (paused \ {xid}) \cup {None}
  /\ (paused \ {xid} = {} => fallback = None)
  /\ (paused \ {xid} /= {} => fallback \in paused \ {xid})
  /\ paused' = paused \ {xid}
  /\ context' = IF paused' = {} THEN "Idle" ELSE "Paused"
  /\ current' = fallback
  /\ ClearObservations

AbortSubtransaction(top, sub) ==
  /\ context = "Paused"
  /\ top \in paused
  /\ sub \in TX
  /\ top /= sub
  /\ context' = "Paused"
  /\ current' = top
  /\ UNCHANGED paused
  /\ emittedInSegment' = FALSE
  /\ emittedHasPrefix' = FALSE
  /\ emittedXid' = None
  /\ emittedNontransactional' = FALSE
  /\ subabort' = TRUE
  /\ abortTop' = top
  /\ abortSub' = sub

EmitSegmentData(xid) ==
  /\ context = "Segment"
  /\ xid = current
  /\ UNCHANGED <<context, current, paused>>
  /\ emittedInSegment' = TRUE
  /\ emittedHasPrefix' = TRUE
  /\ emittedXid' = xid
  /\ emittedNontransactional' = FALSE
  /\ subabort' = FALSE
  /\ abortTop' = None
  /\ abortSub' = None

EmitNontransactional ==
  /\ context \in {"Idle", "Paused"}
  /\ UNCHANGED <<context, current, paused>>
  /\ emittedInSegment' = FALSE
  /\ emittedHasPrefix' = FALSE
  /\ emittedXid' = None
  /\ emittedNontransactional' = TRUE
  /\ subabort' = FALSE
  /\ abortTop' = None
  /\ abortSub' = None

Next ==
  \/ \E xid \in TX : BeginRegular(xid)
  \/ \E fallback \in TX \cup {None} : CommitRegular(fallback)
  \/ \E xid \in TX : StartStream(xid)
  \/ StopStream
  \/ \E xid \in TX, fallback \in TX \cup {None} :
       FinishStream(xid, fallback)
  \/ \E top \in TX, sub \in TX : AbortSubtransaction(top, sub)
  \/ \E xid \in TX : EmitSegmentData(xid)
  \/ EmitNontransactional

THEOREM InitEstablishesInv == DomainOK /\ Init => Inv
<1>. QED BY DEF Init, Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, DomainOK

THEOREM BeginRegularPreservesInv ==
  \A xid \in TX : DomainOK /\ Inv /\ BeginRegular(xid) => Inv'
<1>. QED BY DEF Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, BeginRegular,
                 ClearObservations, DomainOK

THEOREM CommitRegularPreservesInv ==
  \A fallback \in TX \cup {None} :
    DomainOK /\ Inv /\ CommitRegular(fallback) => Inv'
<1>. QED BY DEF Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, CommitRegular,
                 ClearObservations, DomainOK

THEOREM StartStreamPreservesInv ==
  \A xid \in TX : DomainOK /\ Inv /\ StartStream(xid) => Inv'
<1>. QED BY DEF Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, StartStream,
                 ClearObservations, DomainOK

THEOREM StopStreamPreservesInv == DomainOK /\ Inv /\ StopStream => Inv'
<1>. QED BY DEF Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, StopStream,
                 ClearObservations, DomainOK

THEOREM FinishStreamPreservesInv ==
  \A xid \in TX, fallback \in TX \cup {None} :
    DomainOK /\ Inv /\ FinishStream(xid, fallback) => Inv'
<1>. QED BY DEF Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, FinishStream,
                 ClearObservations, DomainOK

THEOREM AbortSubtransactionPreservesInv ==
  \A top \in TX, sub \in TX :
    DomainOK /\ Inv /\ AbortSubtransaction(top, sub) => Inv'
<1>. QED BY DEF Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, AbortSubtransaction,
                 DomainOK

THEOREM EmitSegmentDataPreservesInv ==
  \A xid \in TX : DomainOK /\ Inv /\ EmitSegmentData(xid) => Inv'
<1>. QED BY DEF Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, EmitSegmentData, DomainOK

THEOREM EmitNontransactionalPreservesInv ==
  DomainOK /\ Inv /\ EmitNontransactional => Inv'
<1>. QED BY DEF Inv, TypeOK, ContextOK, SegmentPrefixOK,
                 NontransactionalOK, SubabortOK, EmitNontransactional,
                 DomainOK

THEOREM NextPreservesInv == DomainOK /\ Inv /\ Next => Inv'
<1>. QED BY BeginRegularPreservesInv, CommitRegularPreservesInv,
             StartStreamPreservesInv, StopStreamPreservesInv,
             FinishStreamPreservesInv, AbortSubtransactionPreservesInv,
             EmitSegmentDataPreservesInv,
             EmitNontransactionalPreservesInv DEF Next

=============================================================================
