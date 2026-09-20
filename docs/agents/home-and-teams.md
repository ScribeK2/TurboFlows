# Home pages (CSR, Editor/Admin), featured workflows and team pages

> Part of the agent guidance for TurboFlows, and as binding as `AGENTS.md`, which indexes it.
> Moved here verbatim from `AGENTS.md` on 2026-09-20 so it loads only when the work needs it.
> Cross-references written as "Builder UI §…" mean `docs/agents/builder.md`; "Workflow Engine" and
> "key-services entry" mean `docs/agents/workflow-engine-and-import.md`.

## Home Page

`/` is two pages, and both are about the viewer's own work and nothing else.

A Regular user gets the **CSR home** (`dashboard/csr`, `Dashboard::DataLoader`):
a call to pick back up, what their teams feature for them, their pins, and the
workflows they recently started.
Browsing and pinning are `/play`.
- **No workflow title on it is a link.** A Regular user has no page for a
  workflow, since `WorkflowsController` and `ScenariosController` are closed to
  them, and `POST /play/:id` starts a live call, so Run buttons are the only way
  in. From `263717c8` (2026-04-07) until 2026-09-13 every title, "Manage pins",
  "View all" and Recent Activity row sent a CSR to `/play` with a permission
  error. `test/integration/csr_home_links_test.rb` follows every link on the page
  as a Regular user.
- **Its lists count calls the CSR started** (`Scenario.origins`), because a
  sub-flow or handoff frame carries the same user and purpose as its call. Each
  Recently Run row says how the latest call ended, read from `CallStatistics`,
  in Analytics' words.
- **Resume is one line:** the call with the latest activity inside
  `Dashboard::DataLoader::RESUME_WINDOW` (60 minutes) that still has an
  unfinished frame. Closing the tab is how calls usually end, so most unfinished
  runs are over. It opens the unfinished frame with the latest activity, and
  "Run a Flow" stays the page's filled button.
- **Pins are personal, and only Regular users get a pin toggle** (on `/play` and on
  home), because only the CSR home reads pins. `workflows/pins/_toggle` is the
  only toggle, and `Workflows::PinsController` replaces every copy of it.
- **"From your team" comes before pins.** It shows what the CSR's own groups (direct
  membership, not sub-teams or parents) and Global feature for them.
  - **Headings:** one per team in name order, with Global last as "For everyone". A
    team whose name another of the CSR's teams shares is headed by its path instead
    ("Support / Phone"), since names are unique only under one parent.
  - **What each team shows:** its kit, the first 8 its members can see. The kit is
    cut before anything is left out, so a pin never lets a ninth in. After that, a
    workflow shows once and a pinned one isn't repeated.
  - **Empty and day-one states:** with nothing featured it renders only an empty
    `#team-workflows-section` wrapper, which a pin change replaces. When it has rows
    and the CSR has no pins, "Your fast path" is one line.
  - **Where it's read:** `Dashboard::DataLoader#team_sections`. Every team's
    visibility comes from one batch (`Group.member_visible_workflow_ids`, held to
    `Workflow.visible_to_members_of` by `test/models/workflow_audience_test.rb`), so
    the queries don't grow with the CSR's teams. Pinned and featured rows share
    `dashboard/_launcher_row` and `#run_stats`.

**Featured workflows and the team page.** A group's standard kit
(`GroupFeaturedWorkflow`), curated on its **team page** (`/teams/:id`). "Team page"
means a group's page outside the admin area, and the data is still a group.
- **Who curates:** `TeamCuration` answers for the top-bar "Teams" link, `/teams`, every
  team page and every change. An administrator curates every group, Global included;
  a manager curates their groups and sub-teams (`GroupManager.team_group_ids_for`, the
  reach Analytics uses) and never Global.
- **What it may feature:** only what its members can already see
  (`Workflow.visible_to_members_of`: published, and filed in the group, a subgroup, or
  Global). Featuring never changes who can see a workflow.
- **The cap:** members get at most 8 per group, the first 8 they can see, in the
  curator's order (`GroupFeaturedWorkflow.kit`). A row they can't see holds no place.
  It stays on the team page, marked, until it's removed or visible again, and then it
  returns in its place. That can push a visible row past the 8th. Members don't get it
  on home but can still run it from `/play`, so the team page says "Past the first 8 ·
  not on members' home pages" in plain text rather than with the pill. Adding a ninth
  visible row is refused.
- **The page:** every change answers with a Turbo Stream that replaces
  `#team-featured`. Feature and Remove also report through `#flash`; Move and a drag
  re-render the card in place, so Move up and Move down follow the new order and Move
  keeps focus on the row that moved. A drag that doesn't save (an error such as the
  401 a lost session answers with, no answer, or a redirect such as lost access, which
  the fetch doesn't follow) puts the rows back and says so through `#flash`,
  using `app/javascript/services/flash.js`. Drag reordering uses `sortable-list`, the same
  controller as the admin group page's folders, which renders a stream only when the
  endpoint sends one (the folders endpoint answers an empty 200).

An Editor or Admin gets **home**:
- a hero card for the workflow they were last in;
- "Waiting on you", one row per kind of problem, naming the workflows;
- their other recent workflows;
- for an admin, one strip from `Admin::Attention`.

Org-wide stats and a feed of other people's runs used to live here. Analytics does
the first properly, and the feed's links 404'd for anyone but the run's owner.

- **Last edited is `Workflow.recently_edited`,** the later of the workflow row and
  its newest step, because a step edit never touches the workflow. A
  transition-only change counts as neither, deliberately: `touch:` on `Transition`
  would bump the step's `lock_version` under the step panel's autosave.
- **"Can't publish" is `WorkflowHealthCheck::PUBLISH_BLOCKING_CODES`,** an
  allowlist, not a severity: `no_audience` and the sub-flow codes are warnings, and
  each blocks a publish. Every code the check can emit is classified, and a test
  scans the three emitters. Home runs the check once, for a draft hero only.
- **Every "your" link lands on `/workflows?owner=me`.** An admin's Drafts tab is
  org-wide, so a personal count linked there led to a list of other people's work.
- **Returning to either dashboard must render once:** no entrance animation, no
  Turbo preview, nothing loaded after render. See UIGUIDE § Motion.
