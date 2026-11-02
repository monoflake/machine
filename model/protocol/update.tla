---- MODULE update ----
\* A machine taking its system pointer while its power may be cut at any step, RFC w0w82 and
\* docs/update.md. U-Boot reads /boot in place without replaying its journal, as on pine 2026-11-01.
\* The root's journal is replayed by the kernel, so the store, the profile and the record survive.
EXTENDS Naturals, Sequences, TLC

CONSTANTS
	Top,                  \* The highest generation modeled, 1 the one installed.
	Faults,               \* The cuts, aborts, failed realisations and switches a behavior meets.
	Kinds,                \* The /boot each behavior may have, ext4 its own, vfat, or the root's.
	Aborts,               \* Whether the run may die between its steps with the power still on.
	RECORD_BEFORE_FLUSH,  \* The pointer is recorded after the switch and before /boot is frozen.
	FREEZE_SKIPPED,       \* The switch is followed by the record, /boot never frozen.
	ADOPT_UNSWITCHED,     \* A pointer running but not recorded is recorded alone, never switched to.
	FREEZE_FAILED_RECORDS \* A freeze that did not hold is followed by the record all the same.

Generations == 1..Top
Outcomes == {"ok", "fails", "unasked"}
Freezes == {"held", "unsupported", "unmounted", "failed", "unasked"}
Blank == [pointer |-> "unread", running |-> FALSE, taken |-> FALSE,
	realise |-> "unasked", switch |-> "unasked", freeze |-> "unasked", sync |-> "unasked"]
None == [met |-> Blank, steps |-> <<>>]

VARIABLES
	pointer,   \* The generation the bucket's latest pointer names, CI's `at` only rising.
	listed,    \* Whether that pointer and its signature are in the bucket, which expires them.
	store,     \* The generations whose closure the store holds.
	profile,   \* The generation the system profile names.
	running,   \* The generation running now.
	live,      \* The default entry of /boot as the kernel sees it, its journal applied.
	rest,      \* The default entry of /boot written in place, which U-Boot boots.
	frozen,    \* Whether /boot is frozen.
	recorded,  \* The generation the accepted pointer names, 0 where none was accepted.
	pc,        \* The run's next step, "idle" where none runs.
	target,    \* The generation the run took from the pointer.
	met,       \* What the run found and met, for the fixture.
	steps,     \* The steps the run took, in order.
	last,      \* The run that ended last on its own, for the fixture.
	faults,    \* The faults met so far.
	kind       \* The /boot this machine has.

vars == <<pointer, listed, store, profile, running, live, rest, frozen, recorded, pc, target, met,
	steps, last, faults, kind>>
machine == <<pointer, listed, store, profile, running, live, rest, frozen, recorded>>

\* The order of a switch's steps, as fetch_system takes them and each switch moves them.
Order ==
	IF FREEZE_SKIPPED THEN <<"switch", "record">>
	ELSE IF RECORD_BEFORE_FLUSH THEN <<"switch", "record", "freeze", "thaw">>
	ELSE <<"switch", "freeze", "thaw", "record">>
After(order, s) ==
	LET i == CHOOSE i \in 1..Len(order) : order[i] = s
	IN IF i = Len(order) THEN "done" ELSE order[i + 1]

Init ==
	/\ pointer = 1
	/\ listed \in BOOLEAN
	/\ store = {1}
	/\ profile = 1
	/\ running = 1
	/\ live = 1
	/\ rest = 1
	/\ frozen = FALSE
	/\ recorded \in {0, 1}
	/\ pc = "idle"
	/\ target = 0
	/\ met = Blank
	/\ steps = <<>>
	/\ last = None
	/\ faults = 0
	/\ kind \in Kinds

\* A run ending on its own, which the fixture holds.
Done(m, s) ==
	/\ pc' = "idle"
	/\ target' = 0
	/\ met' = Blank
	/\ steps' = <<>>
	/\ last' = [met |-> m, steps |-> s]

Go(p, m, name) ==
	/\ pc' = p
	/\ met' = m
	/\ steps' = Append(steps, name)
	/\ UNCHANGED <<target, last>>

\* The step after `name` in its order, or the run's end.
\* The step after `after` in its order, or the run's end, having taken `name`.
ThenAs(order, after, name, m) ==
	IF After(order, after) = "done"
	THEN Done(m, Append(steps, name))
	ELSE Go(After(order, after), m, name)
Then(order, name, m) == ThenAs(order, name, name, m)

\* The timer's run reads the pointer, the record and the running system, and decides.
Fetch ==
	/\ pc = "idle"
	/\ LET m == [Blank EXCEPT
			!.pointer = IF listed THEN "present" ELSE "absent",
			!.running = listed /\ running = pointer,
			!.taken = listed /\ recorded = pointer]
	   IN IF listed /\ ~m.taken
		THEN
			/\ pc' = IF m.running /\ ADOPT_UNSWITCHED THEN "record" ELSE "realise"
			/\ met' = m
			/\ steps' = <<>>
			/\ last' = None
			/\ target' = pointer
		ELSE Done(m, <<>>)
	/\ UNCHANGED <<machine, faults>>

Realise ==
	/\ pc = "realise"
	/\ \/ /\ store' = store \cup {target}
	      /\ Go("profile", [met EXCEPT !.realise = "ok"], "realise")
	      /\ UNCHANGED faults
	   \/ /\ faults < Faults
	      /\ faults' = faults + 1
	      /\ Done([met EXCEPT !.realise = "fails"], <<"realise">>)
	      /\ UNCHANGED store
	/\ UNCHANGED <<pointer, listed, profile, running, live, rest, frozen, recorded>>

Profile ==
	/\ pc = "profile"
	/\ profile' = target
	/\ Go(Order[1], met, "profile")
	/\ UNCHANGED <<pointer, listed, store, running, live, rest, frozen, recorded, faults>>

\* switch-to-configuration installs the loader's entry before it activates, so a failed one may
\* leave the entry written; the restore then sets the profile back and switches to what runs.
Switch ==
	/\ pc = "switch"
	/\ ~frozen
	/\ \/ /\ running' = target
	      /\ live' = target
	      /\ Then(Order, "switch", [met EXCEPT !.switch = "ok"])
	      /\ UNCHANGED faults
	   \/ /\ faults < Faults
	      /\ faults' = faults + 1
	      /\ live' \in {live, target}
	      /\ Go("restore_profile", [met EXCEPT !.switch = "fails"], "switch")
	      /\ UNCHANGED running
	/\ UNCHANGED <<pointer, listed, store, profile, rest, frozen, recorded>>

RestoreProfile ==
	/\ pc = "restore_profile"
	/\ profile' = running
	/\ Go("restore_switch", met, "profile")
	/\ UNCHANGED <<pointer, listed, store, running, live, rest, frozen, recorded, faults>>

RestoreSwitch ==
	/\ pc = "restore_switch"
	/\ ~frozen
	/\ live' = running
	/\ Done(met, Append(steps, "switch"))
	/\ UNCHANGED <<pointer, listed, store, profile, running, rest, frozen, recorded, faults>>

\* A run's order, the switch's or the record alone of a pointer already running.
Running == IF met.running /\ ADOPT_UNSWITCHED THEN <<"record">> ELSE Order

\* What a freeze answers on each /boot, an ext4 one failing only as a fault.
Answers ==
	CASE kind = "vfat" -> {"unsupported"}
	  [] kind = "root" -> {"unmounted"}
	  [] OTHER -> {"held", "failed"}

\* A freeze commits the journal and writes it in place. One that cannot hold, as on vfat, is
\* followed by syncfs; one that failed or found /boot on the root ends the run unrecorded.
Freeze ==
	/\ pc = "freeze"
	/\ \E o \in Answers :
		/\ o = "failed" => faults < Faults
		/\ faults' = IF o = "failed" THEN faults + 1 ELSE faults
		/\ rest' = IF o = "held" THEN live ELSE rest
		/\ frozen' = (o = "held")
		/\ LET m == [met EXCEPT !.freeze = o]
		   IN CASE o = "held" -> Then(Running, "freeze", m)
			[] FREEZE_FAILED_RECORDS -> ThenAs(Running, "thaw", "freeze", m)
			[] o = "unsupported" -> Go("sync", m, "freeze")
			[] OTHER -> Done(m, Append(steps, "freeze"))
	/\ UNCHANGED <<pointer, listed, store, profile, running, live, recorded>>

\* syncfs writes vfat in place, having no journal, and only commits an ext4 journal; a failed one
\* ends the run unrecorded.
Sync ==
	/\ pc = "sync"
	/\ \/ /\ rest' = IF kind = "vfat" THEN live ELSE rest
	      /\ ThenAs(Running, "thaw", "sync", [met EXCEPT !.sync = "ok"])
	      /\ UNCHANGED faults
	   \/ /\ faults < Faults
	      /\ faults' = faults + 1
	      /\ Done([met EXCEPT !.sync = "fails"], Append(steps, "sync"))
	      /\ UNCHANGED rest
	/\ UNCHANGED <<pointer, listed, store, profile, running, live, frozen, recorded>>

Thaw ==
	/\ pc = "thaw"
	/\ frozen' = FALSE
	/\ Then(Running, "thaw", met)
	/\ UNCHANGED <<pointer, listed, store, profile, running, live, rest, recorded, faults>>

Record ==
	/\ pc = "record"
	/\ recorded' = target
	/\ Then(Running, "record", met)
	/\ UNCHANGED <<pointer, listed, store, profile, running, live, rest, frozen, faults>>

RunStep ==
	\/ Realise \/ Profile \/ Switch \/ RestoreProfile \/ RestoreSwitch
	\/ Freeze \/ Sync \/ Thaw \/ Record

\* CI publishes a newer pointer, the generation's closure in the bucket.
Publish(g) ==
	/\ g > pointer
	/\ pointer' = g
	/\ listed' = TRUE
	/\ UNCHANGED <<store, profile, running, live, rest, frozen, recorded>>
	/\ UNCHANGED <<pc, target, met, steps, last, faults>>

Expire ==
	/\ listed
	/\ listed' = FALSE
	/\ UNCHANGED <<pointer, store, profile, running, live, rest, frozen, recorded>>
	/\ UNCHANGED <<pc, target, met, steps, last, faults>>

\* The kernel writes /boot's journal in place when it likes, which may be never before a cut.
Writeback ==
	/\ ~frozen
	/\ rest /= live
	/\ rest' = live
	/\ UNCHANGED <<pointer, listed, store, profile, running, live, frozen, recorded>>
	/\ UNCHANGED <<pc, target, met, steps, last, faults>>

Halt ==
	/\ pc' = "idle"
	/\ target' = 0
	/\ met' = Blank
	/\ steps' = <<>>
	/\ last' = None
	/\ faults' = faults + 1

\* U-Boot boots what is in place, then the kernel replays /boot's journal, its last commit
\* kept or lost.
Cut ==
	/\ faults < Faults
	/\ running' = rest
	/\ live' \in {live, rest}
	/\ rest' = live'
	/\ frozen' = FALSE
	/\ Halt
	/\ UNCHANGED <<pointer, listed, store, profile, recorded>>

\* The run dies by a signal between its steps, never inside the freeze it thaws next.
Abort ==
	/\ Aborts
	/\ faults < Faults
	/\ pc /= "idle"
	/\ ~frozen
	/\ Halt
	/\ UNCHANGED machine

Next ==
	/\ \/ Fetch \/ RunStep \/ Expire \/ Writeback \/ Cut \/ Abort
	   \/ \E g \in Generations : Publish(g)
	/\ UNCHANGED kind

\* The timer runs daily and a run goes on; faults are few, and the kernel may never write back.
Fairness == WF_vars(Fetch /\ UNCHANGED kind) /\ WF_vars(RunStep /\ UNCHANGED kind)

Spec == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
	/\ pointer \in Generations
	/\ listed \in BOOLEAN
	/\ store \subseteq Generations
	/\ {profile, running, live, rest} \subseteq Generations
	/\ recorded \in 0..Top
	/\ target \in 0..Top
	/\ met.realise \in Outcomes /\ met.switch \in Outcomes /\ met.sync \in Outcomes
	/\ met.freeze \in Freezes
	/\ kind \in Kinds
	/\ faults \in 0..Faults

\* A cut may fall at any state, and the machine then boots a generation whose closure it holds.
Runnable == rest \in store /\ running \in store

\* A cut may fall at any state, so the pointer recorded never names a generation newer than U-Boot
\* boots, which would leave the machine on the older one with the newer never switched to again.
RecordedBoots == recorded <= rest

\* Once the faults are spent, the machine runs and records the pointer the bucket lists. A /boot on
\* the root's device is never brought to rest, so there the pointer is never recorded.
Converges == <>[](listed /\ kind /= "root" => running = pointer /\ recorded = pointer)

\* Rows for the runner to gather into the fixture, each run that ended on its own.
Word(b) == IF b THEN "1" ELSE "0"
Line(s) ==
	LET f[i \in 0..Len(s)] == IF i = 0 THEN "" ELSE f[i - 1] \o (IF i = 1 THEN "" ELSE ",") \o s[i]
	IN f[Len(s)]
Runs ==
	\/ last = None
	\/ PrintT("run pointer=" \o last.met.pointer \o " running=" \o Word(last.met.running)
		\o " taken=" \o Word(last.met.taken) \o " realise=" \o last.met.realise
		\o " switch=" \o last.met.switch \o " freeze=" \o last.met.freeze \o " sync=" \o last.met.sync
		\o " steps=" \o Line(last.steps))
====
