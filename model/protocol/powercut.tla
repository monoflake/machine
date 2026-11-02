---- MODULE powercut ----
\* The loader contract inside update.tla's atomic switch, docs/update.md and RFC w0w82.
\* An old entry survives while new files land before an atomic default publication.
\* Prepare is an obligation on the external loader, not a guarantee of the current switch child.
\* Without that obligation DEFAULT_BEFORE_REST demonstrates why the updater's later rest is too late.
\* Files are representative independent boot dependencies, including any required device tree.
\* Torn default metadata, disk corruption and firmware fallback are outside this atomic publication model.
\* update.tla separately covers failed switches, retries, root mounts, aborts and pointer publication.
EXTENDS Naturals, Sequences, TLC

CONSTANTS Files, DEFAULT_BEFORE_REST, RECORD_BEFORE_REST, OVERWRITE_OLD

VARIABLES pc, pending, durable, default, selected, recorded, booted, boot_files, kind, steps

vars == <<pc, pending, durable, default, selected, recorded, booted, boot_files, kind, steps>>

Init ==
	/\ pc = "realise"
	/\ pending = {}
	/\ durable = [g \in 1..2 |-> IF g = 1 THEN Files ELSE {}]
	/\ default = 1
	/\ selected = 1
	/\ recorded = 1
	/\ booted = 0
	/\ boot_files = {}
	/\ kind \in {"ext4", "vfat"}
	/\ steps = <<>>

Go(from, into, name) ==
	/\ pc = from
	/\ pc' = into
	/\ steps' = Append(steps, name)
	/\ UNCHANGED <<pending, durable, default, selected, recorded, booted, boot_files, kind>>

Realise == Go("realise", "profile", "realise")
Profile == Go("profile", "write", "profile")

\* Each new file may be cut halfway through, represented by its absence from durable files.
Write ==
	/\ pc = "write"
	/\ \E f \in Files \ pending : pending' = pending \cup {f}
	/\ durable' = IF OVERWRITE_OLD THEN [durable EXCEPT ![1] = {}] ELSE durable
	/\ pc' = IF pending' = Files THEN "prepare" ELSE "write"
	/\ UNCHANGED <<default, selected, recorded, booted, boot_files, kind, steps>>

\* This barrier is a required loader contract, not a step the Rust updater implements.
Prepare ==
	/\ pc = "prepare"
	/\ durable' = IF DEFAULT_BEFORE_REST THEN durable ELSE [durable EXCEPT ![2] = pending]
	/\ pc' = "publish"
	/\ UNCHANGED <<pending, default, selected, recorded, booted, boot_files, kind, steps>>

Publish ==
	/\ pc = "publish"
	/\ default' = 2
	/\ pc' = "activate"
	/\ UNCHANGED <<pending, durable, selected, recorded, booted, boot_files, kind, steps>>

Activate ==
	/\ pc = "activate"
	/\ pc' = IF RECORD_BEFORE_REST THEN "early_record" ELSE "freeze"
	/\ steps' = Append(steps, "switch")
	/\ UNCHANGED <<pending, durable, default, selected, recorded, booted, boot_files, kind>>

EarlyRecord ==
	/\ pc = "early_record"
	/\ recorded' = 2
	/\ pc' = "freeze"
	/\ steps' = Append(steps, "record")
	/\ UNCHANGED <<pending, durable, default, selected, booted, boot_files, kind>>

\* A freeze puts ext4 in place, while unsupported vfat takes syncfs instead.
Freeze ==
	/\ pc = "freeze"
	/\ durable' = IF kind = "ext4" THEN [durable EXCEPT ![2] = pending] ELSE durable
	/\ selected' = IF kind = "ext4" THEN default ELSE selected
	/\ pc' = IF kind = "ext4" THEN "thaw" ELSE "sync"
	/\ steps' = Append(steps, "freeze")
	/\ UNCHANGED <<pending, default, recorded, booted, boot_files, kind>>

Sync ==
	/\ pc = "sync"
	/\ durable' = [durable EXCEPT ![2] = pending]
	/\ selected' = default
	/\ pc' = "record"
	/\ steps' = Append(steps, "sync")
	/\ UNCHANGED <<pending, default, recorded, booted, boot_files, kind>>

Thaw == Go("thaw", "record", "thaw")

Record ==
	/\ pc = "record"
	/\ recorded' = 2
	/\ pc' = "done"
	/\ steps' = IF RECORD_BEFORE_REST THEN steps ELSE Append(steps, "record")
	/\ UNCHANGED <<pending, durable, default, selected, booted, boot_files, kind>>

\* Files and the default may reach disk independently before a requested barrier.
Writeback ==
	/\ pc \notin {"off", "booted"}
	/\ \E landed \in SUBSET pending :
		/\ durable' = [durable EXCEPT ![2] = @ \cup landed]
		/\ selected' \in {selected, default}
	/\ UNCHANGED <<pc, pending, default, recorded, booted, boot_files, kind, steps>>

\* A cut stops the updater even inside the switch, and discards all volatile writes.
Cut ==
	/\ pc \notin {"off", "booted"}
	/\ pc' = "off"
	/\ pending' = durable[2]
	/\ default' = selected
	/\ UNCHANGED <<durable, selected, recorded, booted, boot_files, kind, steps>>

\* The loader reads the default and its files before a kernel could replay any journal.
Boot ==
	/\ pc = "off"
	/\ pc' = "booted"
	/\ booted' = selected
	/\ boot_files' = durable[selected]
	/\ UNCHANGED <<pending, durable, default, selected, recorded, kind, steps>>

Next == Realise \/ Profile \/ Write \/ Prepare \/ Publish \/ Activate \/ EarlyRecord
	\/ Freeze \/ Sync \/ Thaw \/ Record \/ Writeback \/ Cut \/ Boot

Spec == Init /\ [][Next]_vars

TypeOK ==
	/\ pc \in {"realise", "profile", "write", "prepare", "publish", "activate", "early_record",
		"freeze", "sync", "thaw", "record", "done", "off", "booted"}
	/\ pending \subseteq Files
	/\ durable \in [1..2 -> SUBSET Files]
	/\ {default, selected, recorded} \subseteq 1..2
	/\ booted \in 0..2
	/\ boot_files \subseteq Files
	/\ kind \in {"ext4", "vfat"}

\* Every completed boot is the old recorded generation or a complete new generation at rest.
WholeBoot == pc = "booted" => booted \in {1, 2} /\ boot_files = Files
RecordedBoots == pc = "booted" => recorded <= booted

\* The outer order is replayed against Rust, while the loader's inner order remains a contract.
Line(s) ==
	LET f[i \in 0..Len(s)] == IF i = 0 THEN "" ELSE f[i - 1] \o (IF i = 1 THEN "" ELSE ",") \o s[i]
	IN f[Len(s)]
Runs == pc /= "done" \/ PrintT("run pointer=present running=0 taken=0 realise=ok switch=ok freeze="
	\o (IF kind = "ext4" THEN "held" ELSE "unsupported")
	\o " sync=" \o (IF kind = "ext4" THEN "unasked" ELSE "ok") \o " steps=" \o Line(steps))
====
