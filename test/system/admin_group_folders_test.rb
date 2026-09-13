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

  # A drag saves in the background. When the save is refused (here the admin has
  # lost the role since the page loaded, so the endpoint redirects), the folders
  # go back to the order last saved and the page says so.
  test "a drag that saves keeps its order, and one that fails puts the folders back and says so" do
    Folder.create!(name: "Second", group: @group)
    visit admin_group_path(@group)
    assert_equal %w[Before Second], folder_names

    drop_first_folder_last
    assert_eventually { saved_order == %w[Second Before] }
    assert_no_selector "#flash .flash"

    @admin.update!(role: "editor")
    drop_first_folder_last

    assert_selector "#flash .flash--alert", text: "Couldn't save the new order. Try again."
    assert_equal %w[Second Before], folder_names
    assert_equal %w[Second Before], saved_order
  end

  private

  def folder_names
    all(RENAME).map(&:value)
  end

  # The app server shares this test's connection, and a request switches its
  # query cache on, so the same read would keep answering from before the save.
  def saved_order
    Folder.uncached { @group.folders.ordered.pluck(:name) }
  end

  # SortableJS's drag isn't what's under test: this leaves the list the way a drop
  # does and asks the controller to save, as its onEnd callback does.
  def drop_first_folder_last
    page.execute_script(<<~JS)
      const list = document.querySelector("#group-folders [data-controller~='sortable-list']")
      list.append(list.firstElementChild)
      window.Stimulus.getControllerForElementAndIdentifier(list, "sortable-list").reorder()
    JS
  end
end
