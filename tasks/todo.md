# Todo: Session Detail LiveView

Plan: `tasks/plan.md`
Spec: `docs/session-detail-liveview.md`

## Phase 1 — Foundation

- [ ] **T1** Identifier validation + `SessionDetailPresenter` skeleton
      (`validate_identifier/1`, `payload/3` returning live-state only).

## Phase 2 — Slice 1: route works end-to-end

- [ ] **T2** Route `live("/session/:issue_identifier", ...)`,
      `SessionDetailLive` mount/render/handle_info, header + live-state
      section, 404 page, PubSub + runtime tick.

### Checkpoint after T2

- [ ] `make all` green
- [ ] Manual smoke against live state-repo
- [ ] Identifier validation rejects dot-dot/slash in tests
- [ ] Human review

## Phase 3 — Section slices (T3, T4, T5 are independent)

- [ ] **T3** Workspace git log section (`git log --oneline -10`,
      `PathSafety` gate, 2s timeout, degraded states).
- [ ] **T4** Filtered log-tail section (≤5 MiB scan, last 200 matches,
      missing-file degrade).
- [ ] **T5** notes.md + on-disk paths section (memory-tracker
      degrade, four absolute paths).

### Checkpoint after T3–T5

- [ ] `make all` green
- [ ] Manual smoke for every section, including degraded states
- [ ] Presenter branch coverage materially complete

## Phase 4 — Wire-up and docs

- [ ] **T6** Dashboard "View session" links on Running and Retrying
      rows; `README.md` + `elixir/README.md` updates.

### Checkpoint: complete

- [ ] All T1–T6 acceptance criteria checked
- [ ] `make all` green
- [ ] PR body passes `mix pr_body.check`
- [ ] Code review (human or `agent-skills:review`)
