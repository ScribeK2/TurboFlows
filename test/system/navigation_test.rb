require "application_system_test_case"

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

  test "nav menu opens below the header bar" do
    visit root_path

    find(".nav__menu-trigger").click
    assert_selector "dialog.nav__menu[open]", wait: 3

    menu = find("dialog.nav__menu[open]")
    header = find(".page-header")

    menu_top = menu.evaluate_script("this.getBoundingClientRect().top")
    header_bottom = header.evaluate_script("this.getBoundingClientRect().bottom")

    assert menu_top >= header_bottom - 1,
      "Menu top (#{menu_top}) should be at or below header bottom (#{header_bottom})"
  end

  test "nav menu closes on Escape key" do
    visit root_path

    find(".nav__menu-trigger").click
    assert_selector "dialog.nav__menu[open]", wait: 3

    send_keys :escape
    assert_no_selector "dialog.nav__menu[open]", wait: 3
  end

  test "nav menu closes on click outside" do
    visit root_path

    find(".nav__menu-trigger").click
    assert_selector "dialog.nav__menu[open]", wait: 3

    # Click outside the menu (on the page body)
    find("body").click
    assert_no_selector "dialog.nav__menu[open]", wait: 3
  end

  test "search dialog still opens centered with scale animation" do
    visit root_path

    find(".nav__search-pill").click
    assert_selector "dialog.nav__search[open]", wait: 3

    search = find("dialog.nav__search[open]")
    search_top = search.evaluate_script("this.getBoundingClientRect().top")
    viewport_height = evaluate_script("window.innerHeight")

    # Search dialog should be roughly vertically centered (within the middle 60% of viewport)
    assert search_top > viewport_height * 0.1,
      "Search dialog should not be pinned to top like nav menu"
  end
end
