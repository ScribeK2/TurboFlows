require "application_system_test_case"

# The admin Users screens move their dialogs onto native <dialog> + showModal(),
# which only a real browser can prove opens, closes and carries its result.
class AdminUsersTest < ApplicationSystemTestCase
  setup do
    @admin = User.create!(email: "wf-system-test-admin-#{SecureRandom.hex(4)}@example.com",
                          password: "password123!", password_confirmation: "password123!", role: "admin")
    @agent = User.create!(email: "wf-system-test-agent-#{SecureRandom.hex(4)}@example.com",
                          password: "password123!", password_confirmation: "password123!", role: "regular")
    sign_in_as @admin
  end

  teardown do
    Group.where("name LIKE ?", "wf-system-test-%").destroy_all
  end

  test "resetting a password confirms first, then shows the temporary password once" do
    visit admin_user_path(@agent)

    click_on "Reset Password"
    assert_selector "dialog[open]", wait: 3
    assert_text "Generate a temporary password for"

    click_on "Generate Password"
    assert_selector "[data-password-reset-target=password]", text: /\A[a-zA-Z0-9]{16}\z/, wait: 5

    click_on "Done"
    assert_no_selector "dialog[open]"
  end

  # Same rule as the builder's target picker (test/system/builder_focus_test.rb):
  # this error carries role="alert", and a live region has to be in the
  # accessibility tree before its text arrives. It was hidden with .is-hidden -
  # display: none - so it appeared and filled in the same breath, the case
  # assistive technologies are unreliable about.
  test "the password dialog's error region is present and costs nothing while empty" do
    visit admin_user_path(@agent)
    click_on "Reset Password"
    assert_selector "dialog[open]", wait: 3

    box = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("dialog[open] [data-password-reset-target='error']")
        const cs = getComputedStyle(el)
        return { display: cs.display, height: el.getBoundingClientRect().height, text: el.textContent.trim() }
      })()
    JS

    assert_equal "", box["text"]
    assert_not_equal "none", box["display"], "an empty alert region is out of the accessibility tree"
    assert_equal 0, box["height"].to_i, "an empty alert region reserves space"
  end

  # Turbo snapshots the page as you leave it, and a modal does not stop every way
  # of leaving — a scripted visit (the session-timeout redirect) or history.back().
  # Without turbo:before-cache handling the snapshot holds the open dialog, restored
  # on Forward as a bare <dialog open> with no backdrop, and the password shown in it.
  #
  # history.back() runs in the page on purpose: Capybara's go_back goes through
  # WebDriver, and on that path Chrome closes the modal itself, so the test passed
  # with the fix removed.
  test "leaving with the dialog open caches neither the open dialog nor the password" do
    visit admin_users_path
    # A Turbo visit, not a page load: only Turbo's own history restores from its cache.
    execute_script("Turbo.visit(#{admin_user_path(@agent).to_json})")
    assert_selector "h1", text: @agent.email, wait: 5

    click_on "Reset Password"
    click_on "Generate Password"
    assert_selector "[data-password-reset-target=password]", text: /\A[a-zA-Z0-9]{16}\z/, wait: 5

    execute_script("history.back()")
    # Wait for the index to render, not just the URL: popstate changes the URL
    # before Turbo has cached the page being left, and Forward with nothing
    # cached fetches a fresh page — which would pass with the fix removed.
    assert_selector "turbo-frame#users-table", wait: 5
    execute_script("history.forward()")
    assert_selector "h1", text: @agent.email, wait: 5

    assert_no_open_dialog
    assert_equal "", find("[data-password-reset-target=password]", visible: :all).text(:all)
  end

  test "bulk-assigning a group opens a modal dialog whose picker filters by path" do
    department = Group.create!(name: "wf-system-test-dept-#{SecureRandom.hex(3)}")
    target = Group.create!(name: "wf-system-test-emea", parent: department)
    other = Group.create!(name: "wf-system-test-apac", parent: department)

    visit admin_users_path(q: @agent.email)
    click_on "Bulk Assign Groups"
    find("tbody tr", text: @agent.email).find("input[type=checkbox]").check
    within(".admin-bulk-bar") { click_on "Assign Groups" }

    assert_selector "dialog[open]", wait: 3
    within("dialog[open]") do
      find("input.group-picker__filter").set("emea")
      assert_no_selector "li.group-picker__option", text: other.name
      find("li.group-picker__option", text: target.name).find("input[type=checkbox]").check
      click_on "Assign to Selected Users"
    end

    assert_text "Groups assigned to 1 user(s).", wait: 5
    assert_includes @agent.reload.groups, target
  end

  # The same Turbo snapshot trap as the password dialog above, for the bulk dialogs.
  test "leaving with a bulk dialog open does not cache it open" do
    visit admin_user_path(@agent)
    execute_script("Turbo.visit(#{admin_users_path(q: @agent.email).to_json})")
    assert_selector "turbo-frame#users-table", wait: 5

    click_on "Bulk Assign Groups"
    find("tbody tr", text: @agent.email).find("input[type=checkbox]").check
    within(".admin-bulk-bar") { click_on "Assign Groups" }
    assert_selector "dialog[open]", wait: 3

    execute_script("history.back()")
    assert_selector "h1", text: @agent.email, wait: 5
    execute_script("history.forward()")
    assert_selector "turbo-frame#users-table", wait: 5

    assert_no_open_dialog
  end

  private

  # The bug is the open attribute, not what is on screen. A restored
  # <dialog open> fades in from opacity 0 (@starting-style in dialogs.css), which
  # Selenium reports as not displayed, so a visible-only assertion passes during
  # the fade — this one did, with the fix removed.
  def assert_no_open_dialog
    assert_no_selector "dialog[open]", visible: :all
  end
end
