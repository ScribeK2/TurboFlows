# Admin area, groups, audience and self-join

> Part of the agent guidance for TurboFlows, and as binding as `AGENTS.md`, which indexes it.
> Moved here verbatim from `AGENTS.md` on 2026-09-20 so it loads only when the work needs it.
> Cross-references written as "Builder UI §…" mean `docs/agents/builder.md`; "Workflow Engine" and
> "key-services entry" mean `docs/agents/workflow-engine-and-import.md`.

**Admin area.** Every `Admin::` controller inherits `Admin::BaseController`, which
overrides `resolve_layout` to `"admin"` — a nested layout adding the section
sidebar inside the application layout (`content_for :content`). `/admin` is the
**Overview**: only what waits on an administrator, from `Admin::Attention`, which
gathers four model questions — `User.awaiting_groups` (Regular/Editor, not
deactivated, no group, so they see only Global workflows),
`Workflow.published_without_audience` (published and in no group, listed newest
first and linking to the admin-only `/workflows?audience=none`), `SmtpSetting.unconfigured?`
(production only, where no relay means Rails' default of SMTP to localhost:25)
and `JobHealth`. It is built once per request and feeds the sidebar's count too,
so the two cannot disagree; the count is kinds of problem, not records.
**`JobHealth` reads Solid Queue's own tables** (failed executions; recurring
tasks with no run in 26 hours, or a run nothing picked up) because both
inferences from app data false-alarm: a run's clock stops while its parent waits
on a live sub-flow, and an unused instance writes no rollup days. The stalled
check relies on Solid Queue keeping finished jobs for at least a day and switches
itself off if that is shortened. They are kept 7 days (`config/application.rb`), so a
stalled job's last run is still on record: Solid Queue's per-run records of nightly jobs
are deleted with the job, so there is nothing else to read. `JobHealth.worker_down?`
reads the newest `solid_queue_processes` heartbeat against Solid Queue's 5-minute alive
threshold — any fresh process counts, so rows a restart left behind can't hide a live
one — and the Overview counts a down worker as its own kind of problem.
**Data Health lists what `JobHealth` found**, in its Background Jobs section
(`admin/data_health/_background_jobs`, fed the request's `Admin::Attention`):
- failed jobs, newest `JobHealth::LISTED_FAILURES` first, each with its error and
  Retry and Discard. Those are `Admin::FailedJobs::RetriesController` and
  `Admin::FailedJobsController`, calling Solid Queue's own `FailedExecution#retry`
  and `Execution#discard` — a discard deletes the job, not only its failure;
- stalled tasks, each with its schedule and last finished run;
- whether the worker is running, from its heartbeat.

The server notes' "When nightly jobs stall" steps are: check heartbeats, then
`bin/rails restart` (Puma's tmp_restart plugin restarts Puma, and its Solid Queue plugin
restarts the worker), then a container restart the way the platform does it.

Solid Queue runs jobs only in production, so no controller test, system test or dev
browser ever shows a failed-job row; `test/views/admin_background_jobs_partial_test.rb`
renders them from hand-built queue rows. A hand-built job needs real serialized
`arguments` to be retried, and must lose the `ReadyExecution` its `after_create`
made. There is no admin Workflows section: `/workflows`
already gives an admin every workflow and delete.
**Who sees a workflow is its groups, and nothing else.** `Group.reachable_ids_for(user)`
— their groups, those groups' subgroups, and **Global** — is the one input to both
`Workflow.visible_to` and `WorkflowAuthorization`; `test/models/workflow_audience_test.rb`
holds the query and the per-record check together. Global is the root group everyone
signed in sees (`Group::GLOBAL_NAME`). It replaced Uncategorized
(`db/migrate/20260910120000`), which auto-filing filled and almost nobody could see,
and the Public flag (`is_public` is an ignored column now). It is looked up and
never created on read, and it refuses rename, move, delete, subgroups, members
and "Only administrators add people".
The safeguards against someone forgetting to choose ship together and must stay
together:
- new workflows start in no group;
- `WorkflowPublisher` refuses one, and `WorkflowSetPublisher` names every member still waiting;
- the health panel warns first (`:no_audience`);
- the Overview lists published ones;
- an import naming Uncategorized arrives without it, with a `retired_group` warning.

A published workflow in no group is seen by admins and its owner only. Editors may
edit Global workflows another editor owns (what Public allowed). A non-admin's save
can add or remove only groups they reach (`Group.assignable_ids_for`).
`Workflow#replace_groups!` is a diff — the Details panel autosaves every field at
once, and recreating the rows wiped the folder filed on each. The `/workflows`
sidebar lists the top-most groups a person reaches, and a workflow in none of its
group's folders is **Unfiled**.
**People choose their own groups, unless an administrator keeps one.** A Regular or
Editor account in no group (`User#awaiting_groups?`, the one-record form of the
Overview's scope) is sent from the dashboard — and only the dashboard — to
`/welcome`, which `GroupOnboarding` owns together with the dashboard notice and a
session-long Skip. `/profile/edit` has My groups for later. Both write through
`User#join_groups!` / `#leave_group!`, which refuse anything outside
`Group.self_joinable_ids`: not Global, not `admins_add_members`, and **not any group
above or below one that is** — membership covers subgroups, so joining the parent
of a managed group would reach it, and a group that could not be rejoined must not
be left. The rule is enforced on write; hiding a group in the picker is not the
guard. `user_groups.self_joined` records where a membership came from, never
whether anyone reviewed it, so `User#replace_groups!` (both admin writers) is a
diff: wiping and recreating erased every mark on each admin save. Locking a group
removes nobody. Self-join does not touch the workflow-audience safeguards above —
it changes who is in a group, not which group a workflow is in.
**Users** are a table plus a page per user (`/admin/users/:id`). The table row is
email (linking out of its Turbo Frame with `data-turbo-frame="_top"`), the inline
role select, groups and joined; everything else — groups, password reset,
deactivation, workflows owned, last active (newest run, since `:trackable` is
off) — is on the user page. `update_groups`/`deactivate`/`reactivate` return
there; `update_role` uses `redirect_back_or_to` because both surfaces call it.
Group paths come from `Group.tree_nodes` / `Group.paths_by_id` (one query for the
whole tree) and every group picker is `shared/_group_picker`; `Group#full_path`
queries ancestors per call and must not be used in a loop. Every Users dialog is
a native `<dialog>` that closes on `turbo:before-cache` — see UIGUIDE § Dialogs
for why, and for the `visible: :all` trap in testing it.

**Groups** are a tree plus a page per group (`/admin/groups/:id`). The tree renders
flat, depth-first rows from `Group.tree_nodes`, each carrying its ancestor ids, and
`group_tree_controller.js` shows and hides them by set lookup:
- it starts collapsed to the roots;
- a filter matches any part of a path and opens the groups above a match;
- nothing is remembered.

Row counts come from `Group.member_counts` (direct) and
`Group.workflow_counts_including_subgroups`, each equal to what its link lists, and
tested that way (`test/models/group_counts_test.rb`).

A group's page is its department hub:
- subgroups by name;
- direct members, through `Admin::MembershipsController`: a search in a turbo-frame
  that stays open after Add, and Remove with no confirm;
- folders: add by name, rename in place, drag, delete. There are no folder pages
  any more;
- a workflow count linking to `/workflows?group_id=`;
- a delete refused while subgroups or workflows remain, with the page saying so
  instead of offering the button.

Members and folders answer with Turbo Streams that replace their card and update
`#flash` in the application layout. Global's page has only Folders. Groups sort by
name ignoring case everywhere, and have no position column.

**Groups nest up to `Group::MAX_DEPTH` (5) levels**, and the limit is enforced where
it is offered:
- a move checks the whole subtree it carries, not just the moved group (moving a group
  with two levels of subgroups under a fourth-level group used to save it at level 7);
- the check runs only when a group is created or moved, so an already-too-deep group
  can still be renamed;
- the Parent select offers only parents that can take the group and everything under
  it, and always keeps its current parent;
- the group page hides Add Subgroup at the limit and says so.

The member search answers as you type (`debounced-submit`). Its field sits outside the
results frame it fills, because inside it every answer replaced the input being typed in.
