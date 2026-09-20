# STYLE.md

Follow these conventions for every change. RuboCop (with rails, minitest, performance plugins) is enforced — run `rubocop` before commits.

## General
- Explicit > implicit.
- Thin controllers (ideally <10-15 lines per action; move logic to models/services).
- Models can be rich — use app/models/concerns/ for shared behavior.
- One Stimulus controller per logical feature — maintain this granularity; `test/integration/stimulus_controllers_test.rb` fails on a controller nothing mounts.
- Turbo Streams for all dynamic UI updates (avoid full reloads).

## Ruby / Rails
- Public → protected → private method order in classes.
- Liberal use of safe navigation (&.).
- Prefer positive `if` over complex `unless`.
- Complex workflow/execution logic → app/services/ (e.g. ScenarioStepProcessor, StepResolver).
- No business logic in controllers.

## Hotwire & Frontend
- All JS: vendored libs or Stimulus controllers (no external builds).
- Use `turbo_stream_from`, `data-turbo-stream`, turbo_stream helpers.
- Graph Mode rendering/logic: keep in dedicated components/controllers.
- Scenario Mode: state primarily in Scenario model.
- CSS: vanilla + @layer cascade + OKLCH tokens (no Tailwind).

## Testing (Minitest)
- Test every new Step subclass, Transition rule, Scenario execution path.
- Use `assert_difference`, `travel_to` for time-sensitive code.
- System tests (Capybara) for Graph/Scenario/wizard flows.
- **Test the promise a message makes, not just that it appears.** When a message
  tells the user what to do next ("try again", "reload", "pick another"), write
  the test that DOES that and asserts it works. A refused step save told authors
  "change it again to save over theirs" while every retry was refused for ever;
  the test asserted the text and stopped, so a permanently stuck field shipped
  behind 3132 unit and 153 system green (2026-09-20). A browser found it.
- **Mutation-check a test before trusting it.** Break the production line it
  targets and watch that test - not some other one - go red. Four tests on that
  same branch proved nothing, including a concurrency test that took the row
  lock *inside the test*, so it passed with the lock removed from the code. A
  concurrency test must drive the seam the controller calls, never re-implement
  the fix.
- **Run unit before system, and never chain them.** `bin/rails test:system`
  leaves the shared test DB truncated, so a unit run started after one fails
  with ~100 fixture foreign-key violations on `steps` that read exactly like a
  regression. `RAILS_ENV=test bin/rails db:test:prepare` between them.

## Performance & Security
- Fix every Bullet N+1 warning.
- Never bypass Rack::Attack rate limiting.
- Use request-local storage (Current attributes) instead of globals, when needed.

## Naming & Files
- STI Step subclasses: app/models/steps/question.rb, action.rb, sub_flow.rb, etc.
- Channels: app/channels/workflow_channel.rb
- Components: app/components/ (if using ViewComponent later)
- Snake_case filenames, singular where logical.

Match style of existing files: app/models/workflow.rb, app/models/scenario.rb, app/controllers/workflows/base_controller.rb (namespace controller pattern), Stimulus controllers, recent commits (vanilla CSS shift, optimistic locking).

## Maintenance
- When modifying CSS component files in `app/assets/stylesheets/`, verify that `UIGUIDE.md` references are still accurate (class names, file references, component descriptions).
