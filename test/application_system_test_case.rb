require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  SCREEN_SIZE = [1400, 900].freeze

  driven_by :selenium, using: :headless_chrome, screen_size: SCREEN_SIZE do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
  end

  # System tests run with a separate Puma server thread that cannot see
  # records created inside an uncommitted transaction. Disable transactional
  # tests so records are committed and visible to the server.
  self.use_transactional_tests = false

  teardown do
    # Clean up records created during system tests to avoid cross-test pollution.
    # Tests create users with emails matching "builder-test-*" and "system-test-*".
    User.where("email LIKE ?", "wf-system-test-%").destroy_all
  end

  # ── Runner helpers (shared by the Scenario and Player system tests) ──
  #
  # Both runners put the scenario-step Stimulus controller on their step card.
  # That hook is behavioural rather than decorative, so scoping to it survives
  # restyling and keeps assertions off step titles echoed elsewhere on the page
  # (the answered-so-far trail, the page header).
  RUNNER_STEP_CARD = "[data-controller~='scenario-step']".freeze

  # Asserts the given title is the step currently being presented.
  def assert_current_step(title)
    assert_selector "#{RUNNER_STEP_CARD} h2", text: title, wait: 5
  end

  # Selects a radio answer by its visible label. The input is visually hidden by
  # design, so the label is the real affordance — and what a user clicks.
  def choose_answer(label)
    choose label, allow_label_click: true
  end

  # Leaves a finished run for its results page.
  #
  # Finishing no longer navigates on its own: the run's ending stays on the
  # transcript the agent was reading, and results are a link they take when they
  # want them. Tests that used to assert a redirect land here instead.
  def view_results
    assert_text "This run is complete.", wait: 5
    click_on "View results"
  end

  # Sign in via the login form (works with any Capybara driver)
  def sign_in_as(user, password: "password123!")
    visit "/users/sign_in"
    fill_in "Email", with: user.email
    fill_in "Password", with: password
    click_button "Sign in"
    # Wait for successful redirect away from sign-in page
    assert_no_current_path "/users/sign_in", wait: 5
  end

  # ── Builder helpers (shared by the three builder system test files) ──
  #
  # A step row in the builder list, named by its step's uuid rather than
  # counted from the top.
  #
  # Two elements per step carry data-step-uuid: the row itself and the warning
  # icon, which step_warnings_controller un-hides when the step has issues. A
  # bare [data-step-uuid] therefore counts double for any step with a warning,
  # which makes the count depend on when the async health fetch lands. Scope to
  # the row's own class instead.
  STEP_ROW = ".builder__step[data-step-uuid]".freeze
  # A step's whole outline node: its row, its exit door chips (with their
  # nested nodes) and its continuation chip. Scope a stub click here, not to
  # the row: stubs sit on door chips now.
  STEP_NODE = "[role='treeitem'][data-node-uuid]".freeze

  # Opens a step's panel and waits until it is safe to click inside.
  def open_step(step)
    find("#{STEP_ROW}[data-step-uuid='#{step.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5
    assert_panel_settled
  end

  def node_for(step)
    find("#{STEP_NODE}[data-node-uuid='#{step.uuid}']")
  end

  # Chooses a type in the open type picker, whichever door opened it.
  def pick_type(name)
    within(".builder__type-picker") { find(".builder__type-name", text: name, exact_text: true).click }
  end

  # The panel animates open over 250ms and the fields in it re-wrap as it
  # widens, so a button found mid-animation moves before the click lands and
  # the click hits whatever slid under the old spot — about one run in seven.
  # "Wider than 200px" is not enough: the width has to stop changing.
  #
  # Diagnosed in workflow_builder_test.rb, then copied into two more files
  # before it landed here.
  def assert_panel_settled(timeout: 5)
    deadline = Time.current + timeout
    previous = nil
    loop do
      width = panel_body_width
      return if width > 200 && width == previous

      flunk "the panel never settled open (#{width}px wide)" if Time.current > deadline
      previous = width
      sleep 0.1
    end
  end

  # Width of the panel's content box. 0 when closed, ~62% of the builder when
  # open, and 32px in the bug assert_panel_width guards against.
  def panel_body_width
    page.evaluate_script(<<~JS)
      (() => {
        const b = document.querySelector('#builder-panel .builder__panel-body');
        return b ? Math.round(b.getBoundingClientRect().width) : 0;
      })()
    JS
  end

  # Polls a condition the page cannot show — a record an autosave wrote, a
  # broadcast another session received — rather than sleeping a fixed time.
  def assert_eventually(timeout: 5, interval: 0.2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "condition never became true within #{timeout}s"
      end
      sleep interval
    end
  end
end
