require "application_system_test_case"

# Sign-up lands on the dashboard, which a browser follows to the welcome page:
# the filter, the checkbox and Join are the path a new agent takes, and only a
# browser proves the Join button outside its form still submits it.
class GroupOnboardingSystemTest < ApplicationSystemTestCase
  setup do
    @tag = SecureRandom.hex(4)
    @support = Group.create!(name: "wf-system-test-Support #{@tag}")
    @tier2 = Group.create!(name: "Tier 2", parent: @support, description: "Billing and refunds")
    Group.create!(name: "wf-system-test-HR #{@tag}")
    @email = "wf-system-test-onboard-#{@tag}@example.com"
    # Sign-up and sign-in both redirect to first run while no user exists, and
    # system tests do not load fixtures.
    User.create!(email: "wf-system-test-existing-#{@tag}@example.com", password: "password123!",
                 password_confirmation: "password123!", role: "admin")
  end

  teardown do
    # The browser is shared across system tests, so a window one test shrinks
    # stays shrunk for the next: a 500px-tall window made a later test's Back
    # button unclickable. Put it back to the driver's size.
    page.current_window.resize_to(*ApplicationSystemTestCase::SCREEN_SIZE)
    Group.where("name LIKE ?", "wf-system-test-%").find_each do |root|
      Group.where(id: root.descendant_ids).destroy_all
      root.destroy
    end
  end

  test "a new sign-up chooses a group and lands on the dashboard in it" do
    visit new_user_registration_path
    fill_in "Email", with: @email
    fill_in "Password", with: "password123!", match: :first
    fill_in "Password confirmation", with: "password123!"
    click_button "Create account"

    assert_current_path welcome_path, wait: 5
    assert_text "Billing and refunds"

    find(".group-picker__filter").set("tier 2")
    assert_no_selector ".group-picker__option", text: "wf-system-test-HR"
    find(".group-picker__option", text: "Tier 2").check

    click_button "Join"

    assert_current_path root_path, wait: 5
    assert_selector "#flash .flash", text: "You're in wf-system-test-Support #{@tag} / Tier 2."
    assert_no_selector "section[aria-label='Your groups']"
    assert_eventually do
      user = User.find_by(email: @email)
      user && UserGroup.exists?(user: user, group: @tier2, self_joined: true)
    end
  end

  test "Skip for now reaches the dashboard, which offers the way back" do
    user = User.create!(email: @email, password: "password123!", password_confirmation: "password123!")
    sign_in_as user

    assert_current_path welcome_path, wait: 5
    click_button "Skip for now"

    assert_current_path root_path, wait: 5
    within("section[aria-label='Your groups']") { assert_link "Choose your groups" }
  end

  # My groups sits below the profile form. A short window puts it below the fold
  # at the top of the page, so a Join or Leave that reloads the page to its top
  # would leave the person looking at the form instead of what they just changed.
  test "joining and leaving in My groups keeps My groups in view" do
    user = User.create!(email: @email, password: "password123!", password_confirmation: "password123!")
    UserGroup.create!(user: user, group: @tier2)
    sign_in_as user
    page.current_window.resize_to(1400, 500)

    visit edit_profile_path
    assert_operator evaluate_script('document.getElementById("my-groups").getBoundingClientRect().top'),
                    :>=, evaluate_script("window.innerHeight"), "the window must start with My groups out of view"
    within("#my-groups") { find(".group-picker__option", text: "wf-system-test-HR").check }
    within("#my-groups") { click_button "Join" }

    assert_selector "#flash .flash", text: "You're in wf-system-test-HR #{@tag}."
    assert_my_groups_in_view

    within("#my-groups") { click_button "Leave", match: :first }

    assert_selector "#flash .flash", text: "You left"
    assert_my_groups_in_view
  end

  private

  # Checked repeatedly, not once: a Turbo visit renders the new page first and
  # scrolls to its top a moment later, so a single check right after the flash
  # appears can pass on a page about to jump away from My groups. It did, until
  # a /qa pass on 2026-09-11 caught it.
  def assert_my_groups_in_view(for_seconds: 1.5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + for_seconds
    loop do
      top, bottom, height = evaluate_script(<<~JS)
        (() => { const r = document.getElementById("my-groups").getBoundingClientRect();
                 return [r.top, r.bottom, window.innerHeight]; })()
      JS
      assert_operator top, :<, height, "My groups starts below the visible window"
      assert_operator bottom, :>, 0, "My groups ends above the visible window"
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end
end
