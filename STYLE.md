# STYLE.md

Follow these conventions for every change. RuboCop (with rails, minitest, performance plugins) is enforced — run `rubocop` before commits.

## General
- Explicit > implicit.
- Thin controllers (ideally <10-15 lines per action; move logic to models/services).
- Models can be rich — use app/models/concerns/ for shared behavior.
- One Stimulus controller per logical feature (~69 controllers — maintain this granularity).
- Turbo Streams for all dynamic UI updates (avoid full reloads).

## Ruby / Rails
- Public → protected → private method order in classes.
- Liberal use of safe navigation (&.).
- Prefer positive `if` over complex `unless`.
- Complex workflow/execution logic → app/services/ (e.g. ScenarioExecutor).
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

## Performance & Security
- Fix every Bullet N+1 warning.
- Never bypass Rack::Attack rate limiting.
- Use request-local storage (Current attributes) instead of globals.

## Naming & Files
- STI Step subclasses: app/models/steps/QuestionStep.rb etc.
- Channels: app/channels/workflow_channel.rb
- Components: app/components/ (if using ViewComponent later)
- Snake_case filenames, singular where logical.

Match style of existing files: app/models/workflow.rb, app/models/scenario.rb, Stimulus controllers, recent commits (vanilla CSS shift, optimistic locking).

## Maintenance
- When modifying CSS component files in `app/assets/stylesheets/`, verify that `UIGUIDE.md` references are still accurate (class names, file references, component descriptions).
