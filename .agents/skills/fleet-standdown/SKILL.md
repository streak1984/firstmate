---
name: fleet-standdown
description: Stand down Firstmate's subordinate fleet safely before the captain restarts or closes the terminal layer. Use when the captain invokes /fleet-standdown or asks to stand down, stop, shut down, or make the whole fleet dormant before a terminal, session, or Firstmate restart. Owns the readiness judgment, evidence routing, captain surfacing, and blocker classification; delegates deterministic refusal, clean exits, and completion proof to bin/fm-fleet-standdown.sh.
user-invocable: true
metadata:
  internal: true
---

# fleet-standdown

Decide whether the fleet may safely become dormant, clear or surface everything that matters, and only then invoke the deterministic stand-down command.
This skill owns the procedure and judgment.
`bin/fm-fleet-standdown.sh` owns the executable preflight, clean-exit submission, and subordinate completion proof.
Never reproduce the script's adapter, endpoint, polling, or lock mechanics by hand.

## Evidence owners

Derive the decision from these owners rather than from visible panes or an improvised checklist.

| Question | Evidence owner | Stand-down judgment |
| --- | --- | --- |
| Is an ordinary crewmate still active, uncommitted, or unlanded? | `bin/fm-fleet-snapshot.sh --json` owns structured fleet inventory, `bin/fm-crew-state.sh <id>` owns current-state reconciliation, and `bin/fm-teardown.sh <id> --check-only` owns the landed-work test. | Any recorded ordinary crewmate blocks stand-down until its work completes through the normal delivery path and its task is torn down, with a dirty or unlanded result always remaining a hard blocker. |
| Does a secondmate have work in flight or incomplete home evidence? | The registered home's structured summary from `bin/fm-fleet-snapshot.sh --json` is authoritative under `secondmate-provisioning`. | `active_child_work`, unreadable or invalid home state, truncated safety surfaces, contradictions, or a recorded child task block stand-down, while an idle secondmate with complete structured evidence may proceed to the script. |
| Is an open PR ready or already authorized to land? | `bin/fm-bearings-snapshot.sh --json --include-prs` owns live PR enrichment, `AGENTS.md` owns merge authority, and `bin/fm-land.sh <id>` owns the guarded landing chain. | Forge review approval is not captain merge authority, so surface a reviewed PR if authority is missing, but once captain or standing yolo authority exists, run the landing chain and treat any remaining open or failed landing as unlanded-work blocker. |
| Is a captain decision safe to leave for later? | `decision-hold-lifecycle` owns the semantic lifecycle and `bin/fm-decision-hold.sh` owns the durable hold mechanics, while the structured snapshot exposes the resulting `decisions_open`. | Surface every open decision before going dark, allow it to remain unanswered only when durably held in the owning backlog and unrelated to a safety prerequisite, and block status-only or conversation-only decisions until recorded. |
| Is a non-reproducible data store protected? | Because Firstmate has no generic backup-state checker, the data store's documented backup procedure and concrete successful evidence are authoritative, with the owning secondmate returning that evidence through the marked channel owned by `secondmate-provisioning`. | An owning secondmate's `idle` report is not backup proof, so unknown, stale, failed, or assumed backup state for a sole or authoritative copy blocks until the domain owner verifies or remedies it, without an invented generic probe or inference from silence. |
| Are wake events still waiting to be understood? | `bin/fm-wake-drain.sh` owns the durable queue drain, and the supervision protocol owns handling each emitted record. | A non-empty or unhandled wake queue blocks stand-down until it is drained and every record is handled, after which the assessment starts again because a wake may change any later judgment. |
| Did a submitted exit actually stop the agent? | `bin/fm-backend.sh`'s `fm_backend_agent_state` owns the recovery-grade live-agent, dead-shell, missing, ambiguous, unreadable, and unverified distinction, while `bin/fm-fleet-standdown.sh` owns the post-exit reconciliation. | Only `dead` or `missing` proves a recorded endpoint has no live agent, while `alive`, `ambiguous`, `unreadable`, or `unverified` refuses completion regardless of the agent's final message. |
| Is a surviving home-scoped watcher legitimate or leaked? | `bin/fm-supervision-lib.sh` owns whether recorded task metadata or X polling requires supervision, and `bin/fm-wake-lib.sh` owns the identity-bound live watcher proof. | A watcher serving an authoritative supervision need is legitimate and blocks stand-down, a verified live watcher with no such need is a leak that also blocks, and an ambiguous watcher refuses rather than being killed or ignored. |

The only surface-without-answer case is a non-safety captain decision already held durably in the owning backlog.
An item that controls work landing, backup safety, destructive action, or evidence completeness is a blocker even when it also needs the captain's attention.
The fleet is ready only after every blocker clears and every surface-only item has been shown to the captain.

## Procedure

1. **Require the active primary session.**
   Proceed only from the lock-owning primary Firstmate session.
   Leave away mode before starting, and never use this procedure from a lock-refused read-only session.

2. **Drain and handle the wake queue first.**
   Run the wake-drain owner once and process every raw record under the normal supervision protocol.
   If handling a record creates work, a decision, or a failure, reconcile that outcome before continuing.
   Start the assessment again after the drain rather than trusting an earlier snapshot.

3. **Gather complete local fleet evidence and live PR evidence.**
   Load `secondmate-provisioning` before reconciling registered homes and `harness-adapters` before the eventual exits.
   Gather the two owner projections:

   ```sh
   bin/fm-fleet-snapshot.sh --json
   bin/fm-bearings-snapshot.sh --json --include-prs --all-in-flight --all-decisions --all-secondmates --all-recorded-prs --all-unhealthy --all-pr-repos
   ```

   Raise a disclosed owner bound and gather again rather than deciding from an omitted safety-relevant record.
   Refuse judgment when an inventory, home summary, current-state surface, decision surface, or PR surface needed for the decision is unavailable, truncated, contradictory, or stale.

4. **Clear ordinary crewmates through their existing lifecycle.**
   Reconcile every recorded ordinary crewmate with its current-state owner and run teardown's read-only landed-work check.
   Let active work finish, land authorized work through the configured delivery path, and tear the task down normally.
   Never use fleet stand-down as a shortcut for task teardown and never discard a refusal.

5. **Reconcile each live secondmate in its own home.**
   Require its structured summary to show no child work, no undurable captain gate, and no unexplained hold.
   Through the marked return channel, require the secondmate to identify any data store for which its home holds the sole or authoritative copy and cite the domain-specific successful backup evidence, or explicitly attest that it owns no such store.
   Treat a reported or discovered backup gap as a hard blocker and complete the domain's real backup or remediation procedure before continuing.
   Do not restart a dormant secondmate to perform this procedure.

6. **Land what is already authorized and surface what belongs to the captain.**
   For each reviewed open PR, distinguish forge approval from Firstmate merge authority.
   Land it with `bin/fm-land.sh <id>` only when authority already exists; otherwise surface the exact PR and authority needed.
   Surface every durable captain-held decision with its owner and options.
   The captain need not answer a safely parked product decision before stand-down, but a decision that determines landing, backup safety, destructive action, or another prerequisite remains a blocker.

7. **Re-snapshot and make one fail-closed decision.**
   Proceed only when the wake queue is empty, no ordinary crewmate remains recorded, every secondmate is completely and authoritatively idle, authorized PR work is landed, required backup evidence is concrete, and every deferred captain decision is both surfaced and durable.
   Name every blocker or captain-visible item rather than collapsing the result to a generic refusal.

8. **Execute the deterministic mechanics once.**
   Run:

   ```sh
   FM_HOME=<primary-firstmate-home> bin/fm-fleet-standdown.sh
   ```

   Treat any refusal or incomplete proof as a failed stand-down and report its exact evidence.
   A secondmate's statement that it released its lock or is exiting is an assertion of intent, never evidence that its agent is gone.
   Reconcile every recorded direct report against live backend inventory after exit submission and accept only the command's positive `dead` or `missing` proof.
   Refuse completion when an endpoint is still `alive` or its state is `ambiguous`, `unreadable`, or `unverified`.
   A pane that survives harness exit normally falls back to its login shell, so pane existence alone proves neither a live agent nor a failed exit; the backend classifier must distinguish that `dead` shell from both `alive` and `missing`.
   Do not assume the documented harness exit command works merely because its text was delivered, echoed, or cleared from the composer.
   Never send the clean-exit slash command through `fm-send` to a secondmate because that channel wraps steering in marked operational input that the harness consumes as ordinary text.
   Let the deterministic command use the backend's bare unmarked submission primitive, then judge only the resulting inventory evidence.
   The deterministic command makes one clean-exit attempt per live secondmate and waits for a bounded interval rather than resending forever.
   When an agent remains live or unprovable after that attempt, refuse to report a clean stand-down, name the exact endpoint and evidence, and hand the next action to the captain without interrupting, killing, or force-closing it.
   Session locks are PID-bound and become stale when their owning harness process dies, so a captain-chosen hard terminal restart is not itself a lock-corruption path, but that fact grants the stand-down procedure no authority to choose or perform the restart.
   Reconcile the home-scoped watcher separately from the harness agent by asking the supervision owner whether that home still needs monitoring and the watcher owner whether an identity-matched process is actually live.
   Treat a watcher attached to recorded in-flight metadata as legitimate even when a secondmate describes the metadata as stale bookkeeping, because that description does not retire the authoritative record.
   Refuse and surface the stale-record decision without force-cleaning it, fetching in its project, changing project files, or killing the watcher; a verified watcher with no supervision need is instead a leak, but is still left for its lifecycle owner rather than killed by stand-down.
   On success, relay which secondmates stopped, which were already dormant, what persistent state was left untouched, and that nothing restarted.

## Proof boundary

The command deliberately excludes the invoking primary Firstmate session from the stop set.
It keeps that session alive long enough to prove subordinate exits and released secondmate locks and to print the result before the captain restarts the terminal layer.
This ordering cannot prove the later death of the primary session, release of its own lock, completion of the terminal-layer restart, or absence of a new event after the final assessment.
Never describe subordinate completion as proof of those later events.
The next session's normal session-start lock and reconciliation remain the authority for the restarted primary.
