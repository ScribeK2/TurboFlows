require "application_system_test_case"

# The header's chevron menu was deleted 2026-09-09 (every destination is now a
# labelled link, covered by nav_controller_test.rb), and its three tests went
# with it. The search dialog is the header's only dialog.
class NavigationTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    sign_in_as @user
  end

  test "search dialog opens centered with scale animation" do
    visit root_path

    find(".nav__search-pill").click
    assert_selector "dialog.nav__search[open]", wait: 3

    search = find("dialog.nav__search[open]")
    search_top = search.evaluate_script("this.getBoundingClientRect().top")
    viewport_height = evaluate_script("window.innerHeight")

    # Roughly vertically centred: not pinned to the top of the viewport.
    assert_operator search_top, :>, viewport_height * 0.1, "Search dialog should not be pinned to the top of the viewport"
  end
end
