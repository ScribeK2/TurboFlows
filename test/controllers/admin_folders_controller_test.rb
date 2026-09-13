require "test_helper"

# Folders are managed on their group's page (spec Q36). These actions answer
# with the Folders card and a flash; there are no folder pages any more.
class Admin::FoldersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(email: "folderadmin-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "admin")
    @group = Group.create!(name: "Folder Test Group #{SecureRandom.hex(3)}")
    sign_in @admin
  end

  test "the group page lists folders in order, each with a rename field, a count and a confirm naming it" do
    second = Folder.create!(name: "Second", group: @group, position: 1)
    first = Folder.create!(name: "First", group: @group, position: 0)
    2.times do |i|
      GroupWorkflow.create!(group: @group, folder: second, is_primary: true,
                            workflow: Workflow.create!(title: "Filed #{i}", user: @admin))
    end

    get admin_group_path(@group)

    rows = css_select("#group-folders li[data-sortable-id]")
    assert_equal([first.id, second.id], rows.map { it["data-sortable-id"].to_i })
    assert_equal "First", rows.first.at_css("input[name='folder[name]']")["value"]
    assert_match "2 workflows", rows.last.text
    assert_equal "Delete the folder Second? Its 2 workflows become unfiled — still in this group, in no folder.",
                 rows.last.at_css("form[data-turbo-confirm]")["data-turbo-confirm"]
    assert_select "#group-folders [data-controller=sortable-list][data-sortable-list-url-value=?]",
                  admin_group_reorder_folders_path(@group)
    assert_select "#group-folders [name='folder[description]']", 0
  end

  test "adding by name puts the folder last and streams the card back" do
    Folder.create!(name: "Existing", group: @group, position: 4)

    assert_difference("Folder.count") do
      post admin_group_folders_path(@group), params: { folder: { name: "New Folder" } }, as: :turbo_stream
    end

    assert_equal 5, @group.folders.find_by!(name: "New Folder").position
    assert_select "turbo-stream[action=replace][target=group-folders]"
    assert_select "turbo-stream[action=update][target=flash]"
  end

  test "a blank or taken name is refused with the reason, back on the group page" do
    Folder.create!(name: "Taken", group: @group)

    assert_no_difference("Folder.count") do
      post admin_group_folders_path(@group), params: { folder: { name: "Taken" } }
    end
    assert_redirected_to admin_group_path(@group)
    assert_match "Name has already been taken", flash[:alert]

    post admin_group_folders_path(@group), params: { folder: { name: "" } }

    assert_redirected_to admin_group_path(@group)
    assert_match "Name can't be blank", flash[:alert]
  end

  test "renaming saves the name and says what it was" do
    folder = Folder.create!(name: "Old Name", group: @group)

    patch admin_group_folder_path(@group, folder), params: { folder: { name: "New Name" } }

    assert_redirected_to admin_group_path(@group)
    assert_equal "New Name", folder.reload.name
    assert_equal "Renamed Old Name to New Name.", flash[:notice]
  end

  test "a description sent with a rename is ignored" do
    folder = Folder.create!(name: "Keep", group: @group, description: "Original")

    patch admin_group_folder_path(@group, folder), params: { folder: { name: "Kept", description: "Changed" } }

    assert_equal "Kept", folder.reload.name
    assert_equal "Original", folder.description
  end

  test "deleting a folder unfiles its workflows and streams the card back" do
    folder = Folder.create!(name: "Has WFs", group: @group)
    filing = GroupWorkflow.create!(group: @group, folder:, is_primary: true,
                                   workflow: Workflow.create!(title: "WF", user: @admin))

    assert_difference("Folder.count", -1) do
      delete admin_group_folder_path(@group, folder), as: :turbo_stream
    end

    assert_nil filing.reload.folder_id
    assert_select "turbo-stream[action=replace][target=group-folders]"
  end

  test "should reorder folders" do
    f1 = Folder.create!(name: "A", group: @group, position: 0)
    f2 = Folder.create!(name: "B", group: @group, position: 1)
    f3 = Folder.create!(name: "C", group: @group, position: 2)

    patch admin_group_reorder_folders_path(@group), params: { folder_ids: [f3.id, f1.id, f2.id] }

    assert_response :success
    assert_equal([0, 1, 2], [f3, f1, f2].map { it.reload.position })
  end

  test "there are no folder pages, and Manage Folders goes to the group page" do
    helpers = Rails.application.routes.url_helpers
    assert_not helpers.respond_to?(:new_admin_group_folder_path)
    assert_not helpers.respond_to?(:edit_admin_group_folder_path)

    get workflows_path(group_id: @group.id)

    assert_select "a[href=?]", admin_group_path(@group, anchor: "group-folders"), text: /Manage Folders/
  end

  test "non-admins are refused" do
    sign_out @admin
    sign_in User.create!(email: "foldereditor-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "editor")

    assert_no_difference("Folder.count") do
      post admin_group_folders_path(@group), params: { folder: { name: "Nope" } }
    end
    assert_redirected_to root_path
  end
end
