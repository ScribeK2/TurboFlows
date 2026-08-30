require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 900] do |options|
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
end
