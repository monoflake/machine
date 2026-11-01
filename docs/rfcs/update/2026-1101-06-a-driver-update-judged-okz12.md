---
name: 'A Driver Update Judged'
title: 'A driver update is judged after its restart by the driver itself, and a failed check rolls it back'
status: accepted
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

A driver update rolled back only when a service failed to become active. A driver that starts and
then crashes, never answers, or loses a deployment stayed on the machine. What judges an update?

## Evidence

Proved on okra by `ship` on 2026-11-01, each rolling back by itself: a build exiting 8 s after it
starts, at level 1; a build whose router never answers, at level 2; a build answering not_found for a
running deployment, at level 3. A pointer to Release 2026.11.01's 0.1.3 from 0.1.4, a version with no
check command, was kept on level 1 with its warning.

## Decision

Decided by the author on 2026-11-01.

A driver update is judged after its restart by the driver's own program, so the updater reads an exit
code and learns no driver protocol. Before the links move, the version being replaced runs
`driver-machine snapshot <file>`, which reads twice and keeps only deployments running or stopped in
both, a deployment in flight being left out. After the restart the new version runs
`driver-machine check [file]`: level 1, both services active and the same process through a settle
and at the end; level 2, `describe` answers on the driver's port with the new version, and the entry
answers; level 3, the baseline's deployments stand as they were. A non-zero exit, a kill or a timeout
restores the links, restarts the services and records no pointer.

A first install has no baseline and skips level 3. A version with no snapshot command, or a snapshot
that fails, also skips it, and the updater warns that the update passed on levels 1 and 2 alone with
deployments not compared. A move to a lower version, by semver core with a build suffix ignored, whose
target has no check command is kept on level 1 read by the updater, warning that levels 2 and 3 could
not run; the same or a higher version with no check command rolls back.

A change after the baseline to a settled deployment fails the check, since a legitimate delete and a
lost deployment look alike and a rollback costs one window. Bindings with no live token are named and
not judged. The same pointer is tried at the next window or nudge, with no blacklist. Each failed
attempt, at the check or at the restart, is written to `failed-check.json` with its count, shown by
`mise run pointer <machine> --driver`, and cleared when a pointer is recorded.

Level 2 compares the Cargo version, so builds of one version share it and it cannot catch an old
process of an equal version holding the port; that gap is on C alone, as Releases differ. Levels 4 and
5, asking each app through a health path and conform during an update, wait, the deferred item
`driver-check-higher`.
