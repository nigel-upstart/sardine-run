# Todo: Needs-Attention Triage + SR Session Detail

Plan: `tasks/plan.md`
Spec: `docs/plans/needs-attention-triage.md`

## Phase 1 — Foundations (parallel)

- [x] **A** Add `dashboard_url: str | None = None` to `SardineRunRuntime`
      (traffic-control/packages/schema). — `feat/triage-schema` `276fab6`
- [x] **B** TC "Needs your attention" section on `/` (filter, sort,
      tool badge, empty state). — `feat/triage-attention` `31789df`
- [x] **C1** Identifier validation + `SessionDetailPresenter` skeleton
      (sardine-run). — on `feat/sardine-run-migration` `9362607`

### Checkpoint 1
- [ ] A, B, C1 merged.
- [ ] `make all` (SR), `uv run pytest` (TC) green.
- [ ] Manual: triage section visible on TC fleet view.

## Phase 2 — SR slice 1 end-to-end

- [x] **C2** Route + `SessionDetailLive` + live-state + 404
      (sardine-run).

### Checkpoint 2
- [ ] C2 merged. Identifier-injection cases rejected in tests.

## Phase 3 — SR section slices (parallel)

- [x] **C3** Workspace git log section (sardine-run). — `48be550` + `3d0985e`
- [x] **C4** Filtered log-tail section (sardine-run). — `f808eed`
- [x] **C5** notes.md + on-disk paths section (sardine-run). — `046dd11`

### Checkpoint 3
- [ ] C3 + C4 + C5 merged. All five sections rendered for live issue.
- [ ] Degraded states verified.

## Phase 4 — Drill-down + cross-link wiring (parallel)

- [x] **C6** Dashboard "View session" links on Running and Retrying
      rows (sardine-run). — `d861930`
- [ ] **D** SR populates `dashboard_url` on dispatch; clears on
      shutdown (sardine-run).
- [ ] **E** TC "Open in Sardine Run" button on `/sessions/{id}`
      (traffic-control).

### Checkpoint 4
- [ ] C6, D, E merged. End-to-end mutual deep-link verified.

## Phase 5 — Docs

- [ ] **F** `traffic-control/README.md`, `sardine-run/README.md`,
      `sardine-run/elixir/README.md`, `sardine-run/SPEC.md` updates.

### Checkpoint 5 — Done

- [ ] All acceptance criteria from
      `docs/plans/needs-attention-triage.md` met.
- [ ] PRs opened in both repos with the spec linked.
- [ ] `mix pr_body.check` clean for SR PR.
