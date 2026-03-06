require "test_helper"

class Admin::FoldersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "folderadmin@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @group = Group.create!(name: "Folder Test Group")
    sign_in @admin
  end

  test "should get index" do
    Folder.create!(name: "DNS", group: @group)
    get admin_group_folders_path(@group)
    assert_response :success
  end

  test "should get new" do
    get new_admin_group_folder_path(@group)
    assert_response :success
  end

  test "should create folder" do
    assert_difference("Folder.count") do
      post admin_group_folders_path(@group), params: {
        folder: { name: "New Folder", description: "Test", position: 1 }
      }
    end
    assert_redirected_to admin_group_folders_path(@group)
    assert_equal @group.id, Folder.last.group_id
  end

  test "should not create folder with blank name" do
    assert_no_difference("Folder.count") do
      post admin_group_folders_path(@group), params: {
        folder: { name: "", description: "No name" }
      }
    end
    assert_response :unprocessable_content
  end

  test "should get edit" do
    folder = Folder.create!(name: "Edit Me", group: @group)
    get edit_admin_group_folder_path(@group, folder)
    assert_response :success
  end

  test "should update folder" do
    folder = Folder.create!(name: "Old Name", group: @group)
    patch admin_group_folder_path(@group, folder), params: {
      folder: { name: "New Name" }
    }
    assert_redirected_to admin_group_folders_path(@group)
    assert_equal "New Name", folder.reload.name
  end

  test "should destroy empty folder" do
    folder = Folder.create!(name: "Delete Me", group: @group)
    assert_difference("Folder.count", -1) do
      delete admin_group_folder_path(@group, folder)
    end
    assert_redirected_to admin_group_folders_path(@group)
  end

  test "should destroy folder with workflows (nullifies folder_id)" do
    folder = Folder.create!(name: "Has WFs", group: @group)
    workflow = Workflow.create!(title: "WF", user: @admin)
    gw = GroupWorkflow.create!(group: @group, workflow: workflow, folder: folder, is_primary: true)

    assert_difference("Folder.count", -1) do
      delete admin_group_folder_path(@group, folder)
    end

    gw.reload
    assert_nil gw.folder_id
  end

  test "should reorder folders" do
    f1 = Folder.create!(name: "A", group: @group, position: 0)
    f2 = Folder.create!(name: "B", group: @group, position: 1)
    f3 = Folder.create!(name: "C", group: @group, position: 2)

    patch admin_group_reorder_folders_path(@group), params: {
      folder_ids: [f3.id, f1.id, f2.id]
    }

    assert_response :success
    assert_equal 0, f3.reload.position
    assert_equal 1, f1.reload.position
    assert_equal 2, f2.reload.position
  end

  test "should reject non-admin users" do
    sign_out @admin
    editor = User.create!(
      email: "foldereditor@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    sign_in editor

    get admin_group_folders_path(@group)
    assert_redirected_to root_path
  end
end
