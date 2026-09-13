require "application_system_test_case"

# Renaming happens in the browser: Enter saves, Escape puts the name back.
class AdminGroupFoldersTest < ApplicationSystemTestCase
  RENAME = "#group-folders li[data-sortable-id] input[name='folder[name]']".freeze

  setup do
    @admin = User.create!(email: "wf-system-test-folders-#{SecureRandom.hex(4)}@example.com",
                          password: "password123!", password_confirmation: "password123!", role: "admin")
    @group = Group.create!(name: "wf-system-test-Folders")
    @folder = Folder.create!(name: "Before", group: @group)
    sign_in_as @admin
  end

  teardown do
    Group.where("name LIKE ?", "wf-system-test-%").destroy_all
  end

  test "Enter renames the folder, and Escape puts the name back without saving" do
    visit admin_group_path(@group)

    find(RENAME).set("After")
    find(RENAME).send_keys(:enter)

    assert_selector "#flash .flash", text: "Renamed Before to After."
    assert_eventually { @folder.reload.name == "After" }

    find(RENAME).set("Discarded")
    find(RENAME).send_keys(:escape)

    assert_equal "After", find(RENAME).value
    assert_no_selector "#flash .flash", text: "Discarded"
    assert_equal "After", @folder.reload.name
  end

  test "Add Folder puts a new folder at the bottom of the card" do
    visit admin_group_path(@group)

    find("#group-folders input[placeholder='New folder name']").set("Added Last")
    click_on "Add Folder"

    assert_selector "#group-folders li[data-sortable-id]:last-child input[value='Added Last']"
  end
end
