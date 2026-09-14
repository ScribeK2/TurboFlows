# Production replica for load testing

A stand-in for the production VM, built for the 2026-09 department launch and
kept for the company rollout. It is only as faithful as what is known about
production. Where it isn't, this file says so.

## What it reproduces

| Production (2026-09-14) | Replica |
|---|---|
| VM with 4 CPUs, 1.9 GiB, swap | One Docker-in-Docker container (`turboflows-vm`) capped at 4 CPUs, 1800 MiB, 2 GiB swap. Every service below shares that budget |
| Host nginx `stream`: TLS, raw TCP | `loadtest-nginx` with a self-signed certificate on https://localhost:8443 |
| kamal-proxy → web | `kamal-proxy` → `turboflows-web` |
| Every request reaches Rails from one IP | Same: nothing on the path adds `X-Forwarded-For` |
| 2 Puma workers × 5 threads, Solid Queue in-process | Same (`WEB_CONCURRENCY`, `RAILS_MAX_THREADS` unset in production) |
| Postgres ×2, Redis, all on the VM | Same. The second Postgres is idle, since what it holds in production is unknown |
| Migrates on boot | Same (`entrypoint`) |

What it does **not** reproduce:
- the company SSO code (GitLab only), so the replica signs in with passwords;
- the production OS and its page cache;
- whatever else is using the VM's memory. Production swaps at idle and the replica doesn't, so its memory figures are optimistic.

## Run it

```bash
docker build -t turboflows:main-fix .                  # needs config/master.key in the checkout
TURBOFLOWS_IMAGE=turboflows:main-fix test/load/replica/up
test/load/replica/stats 5 > tmp/replica/stats.csv &    # whole-VM memory, swap, CPU as CSV

# data, in order, on an empty database
R="docker exec turboflows-vm docker exec turboflows-web bin/rails runner"
$R /load/seeds/prod_shape.rb      # production's shape: 24 workflows, 8 users, ...
$R /load/seeds/department.rb      # 250 CSRs in five teams, 50 first-sign-in accounts, 12 managers, 5 editors
$R /load/seeds/editor_sandbox.rb  # prints SANDBOX_WORKFLOW_ID / SANDBOX_STEP_IDS for k6
test/load/seeds/history           # 500k finished runs over 91 days via COPY (~90 s), then the backlog roll-up

test/load/replica/down          # stop, keep data
test/load/replica/down --wipe   # stop and delete data
```

Setups from the plan: `VM_MEMORY=1800m` with the defaults (production as it is),
`WEB_CONCURRENCY=1`, and `VM_MEMORY=4g VM_MEMORY_SWAP=6g`. Re-running `up` with new
values applies them to a running replica.

## Run the department test

```bash
START=$(date -u +%Y-%m-%dT%H:%M:%SZ); OUT=tmp/load-results/$(date +%Y%m%d-%H%M); mkdir -p $OUT
docker run --rm --network host -v "$PWD/test/load:/scripts:ro" -v "$PWD/$OUT:/results" \
  -e SANDBOX_WORKFLOW_ID=... -e SANDBOX_STEP_IDS=... \
  grafana/k6 run --summary-export /results/summary.json --console-output /results/console.log /scripts/department.js
test/load/replica/nightly        # mid-test: runs the nightly jobs against live traffic
test/load/checks/run $OUT $START # data checks, 5xx, restarts, memory kills
```

Alongside k6, in another terminal, real browsers (3 CSRs running calls, 1 editor
confirming autosaves persist, and one session left idle for 31 minutes before it
answers):

```bash
IDLE_CHECK=1 SANDBOX_WORKFLOW_ID=... OUT=$OUT/browsers bundle exec ruby test/load/browsers.rb
```

Managers open 7- and 30-day Analytics during the department test. With a quarter's
history, a 90-day view takes ~20 s and pushes the VM into swap, so measure it on its own
afterwards: `ONLY=managers ANALYTICS_RANGES=90d`.

The rush accounts (`rush001`–`rush050`) are first-time users only once. After a run,
take their groups away before the next one:
`$R 'UserGroup.joins(:user).where("users.email LIKE ?", "rush%").delete_all'`.

## Traps already paid for

- **A fresh database never gets the Solid Queue tables from `db:prepare`** when the
  queue shares the primary's `DATABASE_URL`, as it does here and in production. By
  the time `db:prepare` reaches the queue, the database looks initialised. That is
  why the replica uses its own `entrypoint`, which loads `queue_schema.rb` when the
  tables are missing. Until 2026-09-14, `bin/docker-entrypoint` also called
  `db:prepare:queue`, which Rails 8.1 doesn't have, and never created `tmp/pids`, so
  no image built from this repo could boot. Production's GitLab copy had the queue
  line commented out.
- **kamal-proxy's health check sends the target's name as `Host`,** and Rails
  answers only `config.hosts`, which is why web is reached as `healthz`.
- **Rack::Attack counts in fixed one-minute buckets.** A manual burst that
  straddles a minute boundary splits in two and never throttles. Start a check
  early in a minute before concluding a limit is broken.
- **`memory.current` includes page cache,** which the kernel takes back under
  pressure. Loading images leaves the VM "at its limit" with little process memory
  in use. Read `anon_mib` in `stats`, not `mem_mib`.
- **k6 empties every VU's cookie jar after each iteration** unless the options say
  `noCookiesReset: true`. A VU that signs in once then runs signed out from its
  second iteration on. It looks like a server bug: 401s with zero queries, all on the
  Puma worker kamal-proxy happens to be pinned to. And because Devise redirects a
  signed-out page to a 200 sign-in page, k6 records no error unless the script
  checks the final URL. `department.js` does both.
- **`rails runner` scripts share a namespace with Rake's file utilities:** a
  top-level method named `link` (or `cp`, `rm`, ...) calls FileUtils instead.
