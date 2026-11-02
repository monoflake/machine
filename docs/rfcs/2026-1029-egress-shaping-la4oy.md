---
name: 'Egress Shaping'
title: 'Whether a machine behind a provider policer shapes its own egress just below it, with an htb cap and an fq leaf'
status: draft
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

A provider can police a machine's traffic below its port, dropping what passes a rate rather than
queueing it, and TCP reads each drop as congestion. Measured by the advisor on 2026-10-29 with
iperf3 over public IPv4 on 443, ten seconds a run, with BBR over fq, docs/network.md:

- **A machine with a 200 Mbit/s port, policed just below it**: unshaped it ran 164 to 195 Mbit/s,
  retransmitting 14,000 to 30,000 segments in ten seconds. An htb root capped at 205 Mbit/s with a
  128 KiB burst and an fq leaf removed nearly all of them for 5 to 10 Mbit/s less.
- **A machine with a 1 Gbit/s port policed near 700 Mbit/s**, its own counters dropping nothing; a
  cap near 800 Mbit/s is what was measured there.
- **cake was bound by the processor near 300 Mbit/s on two vCPUs**; with `no-split-gso` it kept
  up, and did no better than htb.

The option would be one per machine, absent by default: an egress rate, and its burst, set on the
machine's public interface as an htb root whose one class carries an fq leaf, so BBR's pacing stays
beneath the policer. It is not added, by the author's decision of 2026-10-29, which took the TCP
tuning alone. Open: whether to add it; whether the rate is written by hand from a measurement or
found by the machine; and which interface it names where a machine has more than one.
