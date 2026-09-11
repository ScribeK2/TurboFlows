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
end
