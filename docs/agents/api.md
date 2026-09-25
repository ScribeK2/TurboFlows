# The API and MCP server: tokens, /api/v1, /mcp, /api/docs

> Part of the agent guidance for TurboFlows, and as binding as `AGENTS.md`, which indexes it.
> Written directly here on 2026-09-25 (branch `api-v1`), not moved from `AGENTS.md`.

## What exists

**`ApiToken`** (`app/models/api_token.rb`) is a personal access token: `user_id`,
`name`, `scopes` (a JSON array, `ApiToken::SCOPES = %w[read draft]`),
`token_digest` (unique), `last_used_at`, `expires_at` (`NOT NULL`), `revoked_at`.
`ApiToken.issue(user:, name:, scopes:, expires_in_days:)` mints
`ApiToken::PREFIX` (`"tf_live_"`) + 32 random bytes, stores only
`Digest::SHA256.hexdigest` of it, and stashes the raw value in the unpersisted
`plaintext` accessor so the controller can show it once. Expiry is chosen from
`ApiToken::EXPIRY_CHOICES` (`[7, 30, 90]`, default `ApiToken::DEFAULT_EXPIRY_DAYS`
= 30) and capped at `ApiToken::MAX_LIFETIME` (90 days) by the `expiry_within_limit`
validation, `on: :create` only — an old token is never retroactively invalidated
by a lowered cap. `#allows?(scope)` is checked on every request, not just at
issue: `draft` also requires `user.can_create_workflows?` right now, so demoting
an Editor leaves their token's `read` scope alive and `draft` refused. `#state`
returns `:active` / `:expired` / `:revoked` (never overlapping — revoked wins).

Tokens are managed in two places, both thin views over the model:
- **Profile** (`Profiles::ApiTokensController`, routes under `resource :profile`):
  create and revoke your own tokens. `edit_profile_path` never re-renders a raw
  token once its creation stream has passed.
- **Admin** (`Admin::ApiTokensController`, `resources :api_tokens, only: %i[index destroy]`
  under `namespace :admin`): every token in the install, with a Revoke button
  rendered only for a token whose `#state` is `:active`
  (`app/views/admin/api_tokens/_row.html.erb`'s `<% if token.state == :active %>`)
  — there's nothing to revoke on one already expired or revoked. The sidebar
  item is **"API tokens"** (`AdminHelper::ADMIN_SECTIONS`
  maps `"admin/api_tokens" => :api_tokens`); it needed no new `NavHelper::NAV_SECTIONS`
  entry because `nav_section` already lights Admin for the whole `admin/` prefix.
  `app/views/admin/api_tokens/_row.html.erb` renders a token's `#state` as
  **plain text** (`badge--info`) for both `Active` and `Expired` — expiring is
  not exceptional — and as an **alert pill** (`badge--alert`) only for `Revoked`,
  matching this repo's "pill only for exceptional states" rule
  (`test/controllers/admin/api_tokens_controller_test.rb` "an expired token's
  badge is plain, like Active, not an exceptional pill").

**`/api/v1`** (`config/routes.rb`, `namespace :api, defaults: { format: :json }, format: false`
→ `namespace :v1`): `GET workflows`, `GET workflows/:id`, `GET authoring_guide`,
`POST drafts`, `POST drafts/validate`, `GET openapi.json`. **Not every
controller here inherits `Api::V1::BaseController`, and both exceptions are
deliberate.** `WorkflowsController`, `AuthoringGuidesController` and
`DraftsController`/`Drafts::ValidationsController` do — they need
`Api::TokenAuthentication`, `wrap_parameters false` and the shared
`rescue_from`s. `Api::V1::OpenapiController < ActionController::API` skips it:
the document is public (no token — it describes endpoints, not data), so it has
no authentication to inherit. `Api::V1::NotFoundController <
ActionController::Metal` skips even `::API`: it's the namespace's catch-all for
an unrecognized path, and `::Metal` is what keeps a mistyped path's body from
ever being parsed or logged (see Refusal shapes, below, for why that matters).
The document at `config/openapi/v1.yaml` is the source of truth, served as JSON by
`Api::V1::OpenapiController` at **`GET /api/v1/openapi.json`** and checked
against the live routes by `test/integration/api/v1/openapi_test.rb`, which
fails if a route is undocumented or the document names a route that doesn't
exist, and separately validates the document (and every `$ref` it contains) as
well-formed OpenAPI 3.1 with `json_schemer`.

**`/mcp`** (`McpController`, one route answering GET/POST/DELETE) exposes five
tools through `Api::Mcp::ServerFactory`: `search_workflows`, `get_workflow`,
`get_authoring_guide` (all read-only), `validate_workflow_draft`,
`create_workflow_draft` (both need `draft`). Which tools a token's server offers
is filtered by `ServerFactory.tools_for(api_token)` before `tools/list` ever runs,
so a token never sees a tool it would be refused. **The authoring guide is
readable with either scope, on both faces**: `AuthoringGuidesController`'s
`before_action` accepts `read` or `draft` (only falling through to
`require_scope!(:read)`, and so a 403, when a token has neither), and
`ServerFactory.tools_for` offers `GetAuthoringGuide` to a `read` token AND to a
draft-only one — otherwise a draft-only token would be told by every draft
tool's own description to call a tool it can't see.
`test/integration/api/v1/loose_ends_test.rb`'s "a draft-only token reads the
authoring guide, as MCP already allows" is the REST-side regression test for
this.

**`/api/docs`** (`ApiDocsController`, signed-in HTML, its own layout
`layouts/api_docs`) renders the vendored **Scalar API Reference viewer, 1.72.1**,
unmodified, downloaded from `cdn.jsdelivr.net` on 2026-09-25 and committed at
`vendor/javascript/scalar-api-reference.js` (its header comment carries the exact
source URL and a SHA-256 you can diff a re-download against before ever bumping
the version). To update it: download the new `dist/browser/standalone.js`,
diff against the old one, replace the vendored file, update the header comment's
version/date/SHA-256, and re-run `test/integration/api_docs_test.rb` — it asserts
the script tag names the vendored path and that no `cdn.jsdelivr.net`,
`unpkg.com` or `fonts.scalar.com` reference survives in the rendered page. The
mount point (`app/views/layouts/api_docs.html.erb`'s `<main id="api-docs-viewer">`)
is deliberately **not** `#api-reference`: the vendored bundle's last line runs
auto-init against any element with that exact id at script-load time (the legacy
`<script id="api-reference" data-url>` convention) and would mount a second,
unconfigured instance beside the real one — see the vendored file's header
comment for how that phantom mount was confirmed and killed. `app/views/api_docs/show.html.erb`'s
`Scalar.createApiReference(...)` call turns off Scalar's own hosted features
explicitly, rather than trusting its "only on localhost" heuristic (an internal
install is reachable at more than `localhost`): `hideClientButton: true` (hides
"Open API Client", which would otherwise send this document's URL to
`client.scalar.com` — it does **not** hide "Test Request", left at its default),
`agent: { disabled: true }`, `mcp: { disabled: true }`, `showDeveloperTools: "never"`,
`withDefaultFonts: false`, `telemetry: false`, `proxyUrl: ""`. The CSP was not
loosened for any of this. **What the test actually asserts is narrower than the
full config.** `test/integration/api_docs_test.rb`'s "the init config hides the
client-to-client.scalar.com link and disables Scalar's hosted features" checks
only four of those keys in the rendered page — `hideClientButton: true`,
`agent: { disabled: true }`, `mcp: { disabled: true }`, `showDeveloperTools: "never"`
— plus that `hideTestRequestButton` is never assigned a value. `withDefaultFonts: false`,
`telemetry: false` and `proxyUrl: ""` are set in the view but **unguarded by any
test**: a future edit could drop one of those three silently.

## Authentication

`Api::TokenAuthentication` (`app/controllers/concerns/api/token_authentication.rb`)
is the one seam: `include`d by `Api::V1::BaseController` and `McpController`,
**never** by `ApplicationController` — a session cookie must never authenticate
a token endpoint, which is also why both hosts are `ActionController::API`
subclasses (no session, no cookies, no CSRF) rather than `ApplicationController`
ones. `test/integration/api/v1/authentication_test.rb`'s "a signed-in browser
session alone does not authenticate the API" confirms the outward behavior: it
signs a user in, then hits `/api/v1/authoring_guide` with no bearer header and
still gets 401 — that's `authenticate_token!`'s own check, not the
`attr_reader` below, and would pass identically either way.

**`Devise::Controllers::Helpers` really is mixed into `ActionController::API`,
and the `attr_reader` really does have to beat it.** It's easy to check this the
wrong way: `bin/rails runner 'p ActionController::API.method_defined?(:current_user)'`
answers `false`, because routes haven't loaded yet in that context and Devise
only *defines* `current_#{mapping}` methods when `devise_for` is drawn
(`Devise.add_mapping` → `Devise::Controllers::Helpers.define_helpers`, gem
`devise-5.0.4`'s `lib/devise.rb:368` and `lib/devise/controllers/helpers.rb:113-128`).
`ActionController::API`'s own class body already runs
`ActiveSupport.run_load_hooks(:action_controller, self)` at boot
(`actionpack-8.1.2`'s `lib/action_controller/api.rb:153-154`), which is the hook
`Devise::Engine`'s `"devise.url_helpers"` initializer registers against
(`Devise.include_helpers(Devise::Controllers)`, `lib/devise/rails.rb:23-25`) —
so `Devise::Controllers::Helpers` (which defines `current_user` once
`devise_for :users` runs) is included into `ActionController::API` itself,
ancestry Ruby resolves whether or not this app ever calls it directly. Force
routes to load first and the probe flips:
`Rails.application.reload_routes!; ActionController::API.method_defined?(:current_user)`
is `true`, and `Api::V1::BaseController.instance_method(:current_user).super_method.owner`
is `Devise::Controllers::Helpers` — confirmed directly on this branch. The
concern's `included do` block puts `attr_reader :current_user, :current_api_token`
directly on the including class (`Api::V1::BaseController.instance_method(:current_user).owner`
is `Api::V1::BaseController` itself), the strongest place a method can be
defined, ahead of anything a module in the ancestor chain — Devise's own
`current_user`, sitting right below it — could supply. Both readings memoize
into the same `@current_user` ivar (Devise's is `@current_user ||=
warden.authenticate(scope: :user)`; the `attr_reader` just returns it), and
`authenticate_token!` sets `@current_user` before either could ever be called,
so **no test on this branch can currently tell the two apart** — removing the
`attr_reader` would silently fall through to Devise's memoized read of the same
ivar and still pass every test here. The override is what keeps it that way if
Devise's own method ever stops memoizing, or a future refactor makes
`@current_user` reach a controller action unset.

`authenticate_token!` reads `Authorization: Bearer …` (`ApiToken.raw_from_authorization`,
case-insensitive on "Bearer"), looks it up by SHA-256 digest
(`ApiToken.authenticate`), and refuses with `401` plus
`WWW-Authenticate: Bearer realm="TurboFlows"` for anything short of a live,
unexpired token whose user passes `User#active_for_authentication?` (deactivated
or locked both fail this the same way Devise's own sign-in does) — one shape,
never saying *which* of "missing / unknown / revoked / expired / deactivated /
locked" it was. `require_scope!(scope)` re-checks `ApiToken#allows?` on every
request, not once at issue, and answers `403 insufficient_scope` (REST) when it
fails. A live token records its use at most once a minute
(`ApiToken#record_use!`, a conditional `update_all`), so a busy token costs one
write per minute, not one per request.

The raw token is shown exactly once: in the `turbo_stream.update("api-token-reveal", …)`
response to `POST /profile/api_tokens`. The reveal's wrapper carries
`data-turbo-temporary` (`test/controllers/profiles/api_tokens_controller_test.rb`
"every top-level part of the reveal is marked data-turbo-temporary…") so Turbo's
bfcache snapshot can't resurrect it on Back, and `edit_profile_path`'s own render
never includes it again. The reveal also hands over ready-to-paste setup on
**the request's own host** (`request.base_url`, never a hardcoded `localhost`):

```
claude mcp add --transport http turboflows <URL>/mcp --header "Authorization: Bearer <TOKEN>"
export TURBOFLOWS_TOKEN=<TOKEN>
codex mcp add turboflows --url <URL>/mcp --bearer-token-env-var TURBOFLOWS_TOKEN
curl -H "Authorization: Bearer <TOKEN>" <URL>/api/v1/workflows
```

("Other MCP clients" is the fourth tab, `JSON.pretty_generate` over
`{ mcpServers: { turboflows: { type: "http", url:, headers: { Authorization: } } } }`
— multi-line in the actual UI, not the single-line form the JSON shape above
suggests; `app/views/profiles/api_tokens/_connect.html.erb` is the source.)

## The two seams: `Api::WorkflowCatalog` and `Api::DraftSubmission`

Every REST controller and every MCP tool calls **only** these two services
(`app/services/api/workflow_catalog.rb`, `app/services/api/draft_submission.rb`);
neither ever reaches `Workflow` or `WorkflowImporter` directly. That's what keeps
the two faces from disagreeing about what a token can see or write — widen one
and both widen together, refuse in one and both refuse.

- **`Api::WorkflowCatalog.new(user, base_url:)`**. `#search` unions
  `Workflow.visible_to(user)` (published) with `Workflow.drafts_visible_to(user)`
  (the user's own, or every draft for an admin) — existing visibility rules, not
  new ones — then applies `q` (`Workflow.search_by`), `tag`, `group` and `status`
  filters. Only `group` and `status` raise `Api::WorkflowCatalog::InvalidFilter`
  from inside the catalog (`find_group` on an unknown group id, `checked_status`
  on an unknown status) — `q` and `tag` accept anything and just narrow the
  scope. An **array-valued** filter (`q[]=x`) never reaches the catalog at all:
  `Api::V1::WorkflowsController#index` checks `filters.keys.find { |key|
  !filters[key].is_a?(String) }` first and answers `422 invalid_filter` itself
  — `path` is the offending key, message is `"<key> must be a single value."`
  — so a non-string value is refused rather than silently dropped by either
  layer.
  `#find(id)` (`delegate :find, to: :visible`) raises `ActiveRecord::RecordNotFound`
  for a workflow outside the token's visibility — the controller's
  `rescue_from ActiveRecord::RecordNotFound` turns that into **404, never 403**,
  so existence never leaks. `#summary` and `#document` build the JSON shapes;
  `#document` calls `Workflow#to_strict_document` (`app/models/workflow.rb`), the
  **same** method Export downloads and `get_workflow` returns — "one export
  path" from the spec, so a round trip through the API is exactly as faithful as
  Export always was, no better, no worse (`test/integration/api/v1/drafts_test.rb`
  "GET a workflow, POST it back as a draft: the same workflow").
- **`Api::DraftSubmission.new(user:, api_token:, content:)`**. `#validate`
  checks `oversized?` (`@content.bytesize` over `WorkflowImporter::MAX_IMPORT_BYTES`)
  **first** and, if so, returns `{ valid: false, errors: [oversized_finding],
  warnings: [] }` without ever running the validator; otherwise it runs
  `StrictImportValidator` and reshapes the report into
  `{ valid: report.valid?, errors: report.errors, warnings: report.warnings }`
  — `200` either way, valid or not; the report (reshaped, not the object
  itself) is the answer. `#create` runs, in this fixed order:
  refuse if already oversized → refuse if the draft cap is already full → validate
  → refuse if the incoming bundle would push the cap over → `WorkflowImporter`
  (strict path, stamping `workflows.api_token_id` inside its own transaction).
  The cap check happens **twice** on purpose: once cheaply before validating (so
  an agent already over the limit isn't made to fix ten findings for nothing),
  once after validating (only the validator knows how many workflows are in the
  bundle).

**Provenance.** `workflows.api_token_id` (migration below) is nullable and
`on_delete: :nullify`; `Workflow#api_token` and `Workflow.created_via_api` (a
`where.not(api_token_id: nil)` scope) are what `ApiProvenanceHelper#api_provenance_badge`
and `WorkflowsFilter` read. The badge — **"Created via API · <token name>"**,
exact text — renders whether the token is still live, expired or revoked:
provenance is history, not a live check. Revoking a token keeps the label;
**deleting** the token row nullifies `api_token_id` (the `dependent: :nullify` on
`ApiToken#workflows`) and the label goes with it, though the draft itself
survives. `app/views/workflows/_workflow_list_item.html.erb`'s fragment cache key
(`["wf-row-v5", workflow, current_user, @selected_group, current_user&.role,
@folders&.map(&:id), workflow.api_token]`) includes `workflow.api_token`
explicitly, with a comment explaining why: a token's own destroy nullifies
`api_token_id` via `dependent: :nullify` **without** touching the workflow's
`updated_at`, so `workflow.cache_key` alone would go stale silently.

The **"Created via API" list filter** (`WorkflowsFilter::SOURCE_API = "api"`,
`?source=api`) is threaded through every link that can co-occur with it — the
status tabs, sort dropdown, pagination — via `params[:source]`
(`app/views/workflows/_list_toolbar.html.erb`, `_pagination.html.erb`), so
clicking "Drafts" while the filter is on stays scoped to API-made drafts rather
than silently dropping the filter.

## Logs and Sentry

**`Api::DraftBodyGuard`** (`app/middleware/api/draft_body_guard.rb`) sits
`insert_before 0` in the middleware stack (`config/application.rb`) — first,
ahead of anything that could touch the request body. Its reason for existing:
`ActionController::API`'s Instrumentation builds `request.filtered_parameters`
(which means JSON-parsing the whole body) for the `start_processing.action_controller`
event **before any controller callback runs**, so a `before_action` in
`DraftsController` — what the guard replaced — always fires too late: an
unfiltered document is already on its way to the log. The guard does two things,
for a POST to `/api/v1/drafts` or `/api/v1/drafts/validate`, or **any** method on
`/mcp` (GET/POST/DELETE — the JSON-RPC transport reads a body off all three):
refuse a body over the path's cap (`WorkflowImporter::MAX_IMPORT_BYTES`, 10 MB,
for drafts; `Api::DraftBodyGuard::MCP_MAX_BYTES`, 11 MB — the extra megabyte is
JSON-RPC envelope room, a literal constant rather than a derived one because this
file `require_relative`s before autoloading exists, so `WorkflowImporter` isn't a
resolvable constant yet) with a `413`, body never parsed downstream; otherwise
set `env["action_dispatch.parameter_filter"] = [/./]` so **every** key is masked
in the log, since a document's title, instructions and tags match no
known-sensitive field name in `config/initializers/filter_parameter_logging.rb`
and a fixed list would drift the moment the schema grows a field.

Path matching goes through `ActionDispatch::Journey::Router::Utils.normalize_path`
— the **same** function the router itself uses before matching a route — never a
bare `#chomp("/")` or `#start_with?`. That's what closes `/mcp/`, `/mcp//`,
`/mcp///` and `/api//v1/drafts`: each still routes to a real action (the router
squeezes repeated slashes and drops a trailing one before it ever compares a
path), so a guard comparing the raw, unnormalized path can disagree with the
router and let a variant through unguarded. `Rack::Attack.normalized_path` in
`config/initializers/rack_attack.rb` normalizes the same way, one layer later,
for the same reason.

**Every API route lives inside the one `namespace :api` block** in
`config/routes.rb` (`format: false`, `defaults: { format: :json }`), which is
what keeps `/api/v1/**.<format>` from ever reaching a real endpoint:
`format: false` on the namespace means no `/api/v1/drafts.json`-shaped URL
matches `DraftsController` (or any other real action) — it still **routes**,
but only to the namespace's own `match "*path", to: "v1/not_found#show"`
catch-all (`test/integration/api/v1/drafts_test.rb` "a .json-suffixed drafts
URL routes only to the JSON 404, never to drafts#create"), so
`Api::DraftBodyGuard`'s exact/prefix path match still has nothing real to miss.
A route added outside that block (or above the namespace's own catch-all,
which must stay last inside it) needs to be re-checked against this guard by
hand, since the guard only reads paths, not the router's knowledge of what's
mounted.

**`/mcp` carries its own, separate `format: false`** — it isn't inside
`namespace :api` at all (`match "mcp", to: "mcp#handle", via: %i[get post
delete], as: :mcp, format: false`, `config/routes.rb`), and that matters
because `/mcp` has no catch-all of its own to fall back to: `/mcp.json` doesn't
route to *anything*, a genuine `ActionController::RoutingError`
(`test/integration/mcp_test.rb` "POST /mcp.json does not reach the
controller", which asserts exactly that against
`Rails.application.routes.recognize_path`) — unlike `/api/v1/drafts.json`,
which still lands on the JSON 404 above. Don't conflate the two: a suffixed
`/api/v1/*` URL is caught, a suffixed `/mcp` URL was never routable in the
first place.

**MCP exceptions**: `Api::Mcp::ServerFactory.report_exception` is passed as
`configuration: MCP::Configuration.new(exception_reporter: method(:report_exception))`
**per server instance** (`ServerFactory.build`), never as
`MCP.configuration.exception_reporter` globally — the global hook is called by
the transport layer with **raw, unparsed request bodies**, before `handle_json`
ever runs, so a global reporter would leak whole draft documents into Sentry.
The trade-off named directly in the code: setting it only per-server means an
exception at the transport layer, before a server exists to catch it, is
invisible to this reporter. The per-server reporter itself extracts only the
JSON-RPC `method` and, for a `tools/call`, the tool `name` — arguments are never
forwarded (`Rails.error.report(exception, handled: true, context: { mcp: { method:, tool: } })`).
It has its own `rescue StandardError` wrapping the extraction, because a raise
inside a reporter replaces the SDK's own JSON-RPC error (e.g. the `-32602`
"Tool not found" a scope-filtered call should get) with a bare `-32603 Internal
error` and reports nothing — `test/services/api/mcp/server_factory_test.rb`
covers both the redaction and the crash-tolerance directly, and
`test/integration/mcp_test.rb`'s "an unhandled exception over the real HTTP path…"
drives it through `McpController#handle` for real, not through a direct
`MCP::Server#handle` call, to prove `context[:request]` really does arrive as
the raw JSON-RPC **String** the transport hands the reporter (a Hash only when
a test calls `#handle` directly) — `ServerFactory.parsed_request` handles both
shapes.

## Refusal shapes

**REST**: `{ "errors": [{ "path", "code", "message" }] }`, the same shape
`StrictImportValidator` already used, plus an optional `"warnings"` key.

| Status | When |
|---|---|
| 400 | `malformed_json` — `Api::V1::BaseController`'s `rescue_from ActionDispatch::Http::Parameters::ParseError`, for any non-drafts route whose body Rails' own params parsing actually touches (in practice, a GET with a `Content-Type: application/json` body that fails to parse — see the known gap below) |
| 401 | missing, unknown, revoked or expired token, or a deactivated/locked user |
| 403 | `insufficient_scope` — a scope the token lacks, or the user's role no longer grants it |
| 404 | a workflow that doesn't exist, or that this user can't see — never 403, so existence never leaks; also the JSON catch-all (`Api::V1::NotFoundController`) for any unrecognized `/api/*` path |
| 413 | `payload_too_large` — body over the path's cap, caught by `Api::DraftBodyGuard` before Rails parses it |
| 422 | `invalid_filter` (a bad `q`/`tag`/`group`/`status`, including an array-valued one — `q[]=` is refused, not silently dropped), `unsupported_schema_version`, a `StrictImportValidator` finding, `refused_at_commit`, `api_draft_limit`, and — on the two drafts endpoints only — `malformed_json` (`DraftsController`/`Drafts::ValidationsController` never touch `params`; `Api::DraftSubmission` reads `request.raw_post` directly and lets `StrictImportValidator` report a bad-JSON body as an ordinary finding, so the same failure that's a 400 elsewhere is a 422 here) |
| 429 | `throttled`, with `Retry-After`; body is JSON, never `public/429.html` |

**The JSON 404** is `Api::V1::NotFoundController < ActionController::Metal`, not
`::API` — deliberately, so a mistyped path's body is **never parsed or logged**.
`ActionController::API`'s Instrumentation builds `request.filtered_parameters`
before any action runs, which is exactly the leak `Api::DraftBodyGuard` exists to
close for the two real endpoints it knows about; `Metal` skips Instrumentation
entirely, so a POST to (say) `/api/v1/draft` (missing the `s`) never touches
`params` at all. `NotFoundController` answers no-token the same as a valid one —
401 would confirm the path exists.

**Known gap, not yet closed**: a JSON body sent on a **GET** to
`/api/v1/workflows`, `/api/v1/workflows/:id` or `/api/v1/authoring_guide` still
reaches `ActionController::API`'s Instrumentation and would get parsed and
logged unmasked — `Api::DraftBodyGuard` only guards `/api/v1/drafts*` and
`/mcp`, because those are the only paths a real client sends a body worth
capping or masking on. What's actually proven on this branch is narrower than
the full claim: `test/integration/api/v1/loose_ends_test.rb`'s "a GET whose
body the parser actually touches gets the rescue's 400, not an unhandled
error" dispatches a raw `Rack::MockRequest` GET with a malformed body straight
at Rails (bypassing the integration-test harness, which folds a String
`params:` into the query string on a GET and can't reach this path at all) and
confirms the body really is parsed — `BaseController`'s `rescue_from
ActionDispatch::Http::Parameters::ParseError` fires — and that the failure is
safe, a 400 `malformed_json`, not a crash. **No test on this branch proves the
other half: that a well-formed GET body actually reaches the log
unmasked.** That would take a `start_processing.action_controller` notification
subscriber (the pattern `test/integration/api/v1/drafts_test.rb` uses for the
drafts POST routes) driven against a GET with a valid JSON body and no such
test exists for `/api/v1/workflows` et al. Predates this task; filed here as an
open follow-up, not fixed by it, and not fully test-covered as a leak either.

**MCP**: refusals are **tool results** (`isError: true`), in the same
`{ errors:, warnings: }` shape (`Api::Mcp::ToolResult.refused` /
`.refusal`), never a JSON-RPC protocol error — so a model reads the findings
and retries, the same loop REST gives it. One documented exception: a call that
violates a tool's own `input_schema` (unknown argument, wrong type, an enum
value outside its list, a missing required argument — every schema sets
`additionalProperties: false` for exactly this) never reaches tool code at all;
the SDK's own schema gate answers it as a **text-only** `isError` result naming
the offending argument, with no structured `code` (spec §3, amended in Phase 2).
`test/services/api/mcp/server_wire_test.rb` is the test that drives this — see
Traps below for why it matters that it does. **A missing scope reads differently
on each face**: REST answers `403 insufficient_scope`; MCP omits the tool from
`tools/list` for that token (`ServerFactory.tools_for`), and a call to it anyway
hits the SDK's own routing and comes back **`-32602 Invalid params`, "Tool not
found"** — a genuine JSON-RPC error, because the tool was never offered to begin
with, not a refusal the model is meant to act on
(`test/integration/mcp_test.rb` "a read token calling create_workflow_draft
anyway writes nothing"). The two draft tools also each carry their own
in-code scope guard (`return DraftDocument.refused_scope unless
server_context[:api_token].allows?(:draft)`), belt-and-braces against the tool
ever being reachable with a stale `tools/list`.

**401** always carries `WWW-Authenticate: Bearer realm="TurboFlows"`. **429**
(Rack::Attack) is JSON with `Retry-After` for anything under `Rack::Attack.api?`;
everywhere else it's the existing HTML `429.html`.

## Rate limits

Four throttles in `config/initializers/rack_attack.rb`, all keyed on
`"token:#{ApiToken.digest(raw)}"` (the SHA-256 digest, computed **before**
authentication — a flood of made-up tokens gets a fresh bucket per fake token,
so only the company-wide backstop catches that; the per-token limits exist to
keep one real, well-behaved client from starving others, not as the abuse
defense):

| Throttle | Limit | Counts |
|---|---|---|
| `api/token/read` | 120/min | any GET under `/api/v1/` |
| `api/token/draft` | 20/min | POST to `/api/v1/drafts` or `/api/v1/drafts/validate` |
| `api/token/mcp` | 60/min | every `/mcp` call, whatever the JSON-RPC method — the throttle can't see which tool without parsing the body, which Rack::Attack shouldn't do, so `initialize` and `tools/list` count too |
| `api/all` | 1200/min, key `"all"` | every `rest?` or `mcp?` request, company-wide backstop |

`Rack::Attack.rest?(req)` is narrowed to the **`/api/v1/`** prefix specifically
— not the wider `/api/` — so `/api/docs` (a signed-in browser page, not a
token call) counts toward neither `api/token/read` nor `api/all` and can never
come back as the API's JSON 429; a throttled hit on it gets the ordinary HTML
page like every other page in the app
(`test/integration/rack_attack_test.rb` "rest? is false for /api/docs…" and
"a throttled /api/docs request answers with the readable page, never the API's
JSON body"). An unknown path outside `/api/v1/` (say `/api/v2/anything`) isn't
throttled by the API rules at all — the namespace's own catch-all 404s it before
any throttle would matter.

`Rack::Attack.mcp?` / `.rest?` / `.drafts?` call
`Rack::Attack.normalized_path`, which — like `Api::DraftBodyGuard` — uses
`ActionDispatch::Journey::Router::Utils.normalize_path` rather than trusting
rack-attack's own `PathNormalizer` (which already runs earlier in the same
request and would make the two agree anyway in production; the direct calls in
`test/integration/rack_attack_test.rb` are what actually exercises this
helper's own correctness, since a full-stack request can never observe it
disagreeing with rack-attack's prior normalization). **rack-attack 6.8 itself
also normalizes** the path before any throttle block runs — noted so nobody
"fixes" what looks like double normalization.

## Decisions to know

- **The draft cap is 50 outstanding API-made drafts per user, and still not
  atomic across requests.** `Api::DraftSubmission#outstanding` memoizes
  (`@outstanding ||= Workflow.drafts.created_via_api.where(user: @user).count`),
  so within one `#create` call the two cap checks (before and after validating)
  read the count exactly once, not twice — but nothing locks the row *between
  separate requests*, so two near-simultaneous creates from different requests
  can each see the same pre-write count, both pass, and land at 51. Bounded in
  practice by the 20/min draft throttle. `422 api_draft_limit` tells the caller
  to have a person review, publish or delete some.
- **The 10 MB document cap is enforced in two places, deliberately.**
  `Api::DraftBodyGuard` refuses an oversized *transport* body before it's ever
  parsed (413, for both `/api/v1/drafts*` and `/mcp`). `Api::DraftSubmission#oversized?`
  refuses again, inside the shared seam, against `@content.bytesize` — because
  `Api::DraftBodyGuard::MCP_MAX_BYTES` (11 MB) has a full megabyte of headroom
  over `WorkflowImporter::MAX_IMPORT_BYTES` (10 MB) for the JSON-RPC envelope
  (`method`, tool name, the `arguments` key), so a document between the two
  sizes passes the middleware on `/mcp` but must still be refused by the one seam
  both REST and MCP call — otherwise a document too big to create over REST
  could be created over MCP.
- **A Sub-Flow step's `target_workflow_title` in a strict document can name a
  workflow the reader can't see.** Inherited from Export, which has always
  emitted the target by title regardless of the exporting user's own visibility
  into it; the API round-trips the same document Export always produced, no
  more and no less faithful.
- **MCP is stateless** (`stateless: true, serve_subscriptions_listen: false` on
  `MCP::Server::Transports::StreamableHTTPTransport`), required rather than
  preferred: production runs several Puma workers (`WEB_CONCURRENCY`) and the
  SDK's session state lives per-process, so nothing may depend on a session
  surviving from one request to the next. The cost is server-sent notifications,
  which v1's tools don't use. `GET /mcp` in stateless mode answers a plain
  **405** (`test/integration/mcp_test.rb` "GET /mcp in stateless mode is exactly
  405"), and a JSON-RPC *notification* (no `id`) gets a bodyless **202** ack —
  `McpController#handle` calls `head status` rather than letting an empty
  `response_body` fall back to Rails' default `text/html` content type.
- **`dns_rebinding_protection: false`** on the transport, because
  `config.hosts` (`config/environments/production.rb`, from `APP_HOST`) already
  checks every request's `Host` header in production — a second allow-list
  inside the MCP transport would be one more thing to keep in step with it, and
  the SDK's own `allowed_hosts` only *extends* its loopback defaults anyway, so
  disabling this costs nothing in dev.

## Traps that cost an afternoon on this branch

- **`/mcp/`, `.json` suffixes, `/mcp//`, and `/api//v1/drafts` were each their
  own separate bypass, fixed by three different commits — don't cite the wrong
  one.** `968ca3fa` gave `/mcp` its own `format: false` (closing `/mcp.json`)
  and taught the guard to strip one trailing slash (`chomp("/")`, closing
  `/mcp/`) — but `chomp("/")` only strips *one* slash, so `/mcp//` and
  `/mcp///` still routed (the router squeezes repeated slashes before
  matching) and slipped past unguarded. `e26a5505` separately put
  `format: false` on the whole `/api` namespace, closing every
  `/api/v1/*.json` suffix the same way. Neither of those touched the deeper
  bug: `723c18a4` is the commit that replaced the `chomp("/")` approach with
  the router's own `ActionDispatch::Journey::Router::Utils.normalize_path` (see
  Logs and Sentry, above), which is what actually closes `/mcp//`, `/mcp///`
  and `/api//v1/drafts` — a guard written against `chomp("/")` alone still has
  a gap today if you're reasoning from `968ca3fa` and stop there.
- **The MCP exception reporter crashing on the real HTTP request shape.**
  `context[:request]` is a parsed `Hash` only when a test calls
  `MCP::Server#handle` directly; over the real HTTP path the transport calls
  `#handle_json(body_string)`, and every rescue closes over that raw **String**.
  A reporter written and tested only against the Hash shape (as
  `test/services/api/mcp/server_wire_test.rb` deliberately calls `#handle`, not
  `#handle_json`, and would never catch this) raised the moment a real client
  hit it, replacing the SDK's own JSON-RPC error with a bare `-32603` and
  reporting nothing (commit `e7e487ee`). Fixed by `ServerFactory.parsed_request`
  handling both a Hash and a JSON String, wrapped again in its own
  `rescue StandardError`.
- **Tests that called a tool directly (`Tool.call(...)`) instead of through
  `MCP::Server#handle` or real HTTP** proved nothing about schema refusals: a
  direct call skips the SDK's own `input_schema` gate entirely, so a test built
  that way can't tell a text-only schema `isError` apart from tool code that
  never ran. `test/services/api/mcp/server_wire_test.rb`'s header comment says
  this outright — "Drives tools through the real wire… not a direct Tool.call"
  — and every one of its schema-refusal tests goes through `@server.handle`.
  `test/integration/mcp_test.rb` goes one layer further still, through
  `McpController` over real HTTP, which is what actually caught the exception
  reporter bug above.
- **The harness blocking security-weakening mutation checks.** The spec's own
  Testing section calls for a mutation check on visibility — widen
  `WorkflowCatalog`'s scope and confirm the relevant test goes red. That edit is
  itself security-weakening, and the harness that guards this repo can refuse
  to make it even temporarily for a test run. No fix is recorded on this
  branch; if you hit the same refusal, that's expected, and the mutation check
  for that test is still owed.

## Migrations and what ships

Two migrations, both additive: `db/migrate/20260925120000_create_api_tokens.rb`
(new table) and `db/migrate/20260925120100_add_api_token_to_workflows.rb`
(`workflows.api_token_id`, nullable, `on_delete: :nullify`, no backfill —
nothing existing was ever made through the API). Neither locks anything large.
New runtime gem: `gem "mcp", "~> 1.6"` (one dependency, `json_schemer`).
`/mcp` relies on `config.hosts`; curl it once from inside the network right
after deploying. **"Nothing is reachable until a token exists" overstates
it** — `GET /api/v1/openapi.json` and `/api/docs` (signed-in) are both
token-free by design, and the catch-all answers anyone. What's actually true:
no workflow data is reachable, and nothing can be written, until someone
creates a token — tell IT and the AI team what a `tf_live_` token is before
announcing this.
