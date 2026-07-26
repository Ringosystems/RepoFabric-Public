# Cross-repo communications automation (RepoFabric &lt;-&gt; ConfigFabric)

Operated by RingoSystems Heavy Industries. This is the plan for automating the
back-and-forth issue/feature coordination between the two fabric-family repos,
**Ringosystems/RepoFabric** (WinGet delivery fabric) and
**Ringosystems/ConfigFabric** (DSC configuration fabric), so paired integration
issues, decision-register answers, and status hand-offs propagate promptly and
without manual copy-paste.

## Goal

Today coordination is manual: a person files a paired issue on one repo, links
it to the other, the peer side answers in a comment, decisions get ratified by
hand (the M6 decision register), and someone watches CI/reviews. The goal is a
**timely, fully automated pipeline** that:

1. mirrors integration activity between the paired issues on both repos,
2. drafts and (when safe) posts the substantive response on the peer side,
3. tracks who-owes-what with a label state machine and a daily digest,
4. nudges/escalates anything that breaches its response SLA,

while keeping a human in the loop for genuine design decisions.

## Governance: RepoFabric is the approving primary

RepoFabric is the **approving primary** for the RepoFabric <-> ConfigFabric relationship. A cross-fabric decision **signed off on the RepoFabric side is final and binding**: once it is marked `decided` here (or is covered by a ratified M6 answer), ConfigFabric defers and implements against it, with **no separate ConfigFabric ratification step**. There is no round-trip wait; the peer does not re-confirm a RepoFabric sign-off.

Who may set `decided` (the final sign-off): the human primary, or the interactive RepoFabric agent ratifying user-approved decisions. The headless responder does **not** unilaterally finalize a net-new design decision; it drafts options plus a recommendation and applies `awaiting-human` for the primary to sign off. Once `decided` is set on the RepoFabric side, the responder treats it as final and propagates the sign-off to the paired ConfigFabric issue.

State transition for a decision: `awaiting-decision` -> (primary signs off in RepoFabric) -> `decided` (final) -> peer notified -> ConfigFabric implements.

## Architecture: three layers

```
            GitHub events (issues, issue_comment, PR, label)
                              |
   +--------------------------+---------------------------+
   |                          |                           |
Layer 1: peer-sync       Layer 2: peer-responder     Layer 3: peer-sweep
(deterministic)          (intelligent, Claude)       (scheduled SLA)
mirror + label SM        triage + draft + post       nudge + digest
   |                          |                           |
   +-----------> one cross-repo token / GitHub App <------+
```

- **Layer 1 - `peer-sync` (deterministic, no AI).** GitHub Actions on
  `issues` / `issue_comment` for issues carrying the `integration` label.
  Mirrors a pointer comment to the paired issue on the other repo and drives the
  label state machine. Fast, reliable, cheap. Handles "a new comment landed on
  the paired issue", "the peer issue was closed", etc.
- **Layer 2 - `peer-responder` (intelligent).** The Claude GitHub Action,
  triggered on the same integration events, triages the ask and drafts the
  substantive reply (answer a contract question from the codebase + decision
  register, update a checklist, propose an interface). It **auto-posts low-risk
  replies** (acknowledgements, status, factual answers verifiable from code) and
  **escalates genuine decisions** (e.g., the Q2 constraint grammar) to a human by
  applying `awaiting-human` and opening a review request instead of committing
  the decision. This is the layer that closed the M6 register by hand; it does it
  automatically going forward.
- **Layer 3 - `peer-sweep` (timeliness).** A scheduled job (every 2h) that scans
  both repos for items past their response SLA and nudges them, plus posts a
  daily cross-repo status digest to a pinned coordination issue. The safety net
  so nothing stalls even if an event is missed.

## The pairing convention (machine-readable)

Every integration issue declares its counterpart with an HTML-comment marker in
the body (invisible when rendered), added by the integration issue template:

```
<!-- peer: Ringosystems/ConfigFabric#1 -->
```

`peer-sync` reads this marker to know where to mirror. The existing
`from-repofabric` / `from-configfabric` labels identify origin; `integration`
gates all automation.

## Label state machine

| Label | Meaning | Set by | Cleared by |
|---|---|---|---|
| `integration` | Spans both repos; gates automation | author/template | n/a |
| `awaiting-peer` | This repo is waiting on the partner to act | peer-sync on outbound | peer-acked |
| `awaiting-decision` | A cross-cutting decision is pending ratification | responder | decided |
| `awaiting-human` | Responder escalated a real decision for review | responder | a human |
| `peer-acked` | Partner has responded / acknowledged | peer-sync on inbound | next round |
| `blocked-by-peer` | Work blocked pending partner-repo delivery | responder/human | when unblocked |
| `decided` | Decision ratified; ready to implement | human (checkbox) | n/a |
| `auto-mirrored` | Comment/state written by the bot (loop guard) | peer-sync/responder | n/a |

Transitions (happy path): outbound comment -&gt; `awaiting-peer`; peer mirror
arrives -&gt; `peer-acked`; responder posts an answer -&gt; back to `awaiting-peer`
on the other side; decision checkbox ticked in the register -&gt; `decided`.

## Workflows (this directory)

All three live in `.github/workflows/` on **both** repos (symmetric). They are
**inert until the `PEER_REPO_TOKEN` secret exists** (each job guards on it), so
merging them changes nothing until you opt in.

- `peer-sync.yml` - Layer 1. Mirrors comments/closure to the paired issue and
  manages `awaiting-peer` / `peer-acked` / `auto-mirrored`. Loop-guarded (skips
  bot authors and `auto-mirrored` content).
- `peer-responder.yml` - Layer 2. Runs the Claude action on integration
  issue/comment events to triage and draft/post the reply, with the
  decision-escalation gate.
- `peer-sweep.yml` - Layer 3. `schedule` every 2h + manual dispatch; nudges
  past-SLA items and refreshes the digest.

## Auth: one prerequisite

Cross-repo writes cannot use the default `GITHUB_TOKEN` (it is scoped to the
current repo). Provision **one** of these and store it as the secret
`PEER_REPO_TOKEN` on **both** repos (or as an org secret shared to both):

1. **GitHub App (recommended).** A small org-owned App installed on both repos
   with `Issues: read & write` and `Metadata: read`. Use
   `actions/create-github-app-token` in the workflow to mint a short-lived
   installation token. No expiry to babysit, higher rate limits, least
   privilege, and every action is attributable to the App identity.
2. **Fine-grained PAT (fastest to set up).** A fine-grained personal access
   token scoped to exactly these two repos with `Issues: Read and write`. Store
   as `PEER_REPO_TOKEN`. Simpler now; remember to rotate before expiry.

Layer 2 additionally needs `ANTHROPIC_API_KEY` (the Claude GitHub Action), or it
can reuse the existing Claude GitHub App if that is how the current PR webhooks
are wired.

## Guardrails

- **Loop prevention.** Mirrored content carries an `auto-mirrored` label and an
  HTML marker; the workflows skip anything authored by the bot or carrying that
  marker, so a mirror never triggers another mirror.
- **Idempotency.** Before posting a mirror the workflow checks for an existing
  mirror of the same source comment id (recorded in the marker), so re-runs do
  not duplicate.
- **Confidence gating.** The responder auto-posts only acknowledgements, status,
  and answers it can ground in the codebase + decision register; anything that
  commits a design decision gets `awaiting-human` and a review request, never an
  auto-commit.
- **Least privilege.** The token grants Issues write only - never Gitea creds,
  never code push.
- **Auditability.** Every automated comment is labelled and signed with a footer
  so a human can always see what the bot did and undo it.

## Rollout

1. **Phase 0 (done).** Symmetric issue templates, matching label sets, and the
   state-machine labels on both repos.
2. **Phase 1.** Merge these workflows (inert), provision `PEER_REPO_TOKEN`, add
   the `<!-- peer: ... -->` marker to the existing paired issues (#2/#3/#4 here,
   #1/#2/#3/#4 there). Enable `peer-sync` first and watch one round.
3. **Phase 2.** Turn on `peer-responder` in draft-only mode (it posts replies
   prefixed "DRAFT - " for a human to approve), then graduate to auto-post for
   the low-risk classes once you trust it.
4. **Phase 3.** Enable `peer-sweep` and the daily digest; set the SLAs.

## Manual fallback

Everything the pipeline does can still be done by hand (it is just `gh issue
comment` + labels). If the token is absent or a workflow is disabled, the repos
behave exactly as today, no coordination is lost, it just is not automated.
