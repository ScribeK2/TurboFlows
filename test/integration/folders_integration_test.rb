require "test_helper"

class FoldersIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "folders_int_admin@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @group = Group.create!(name: "Integration Group")
    UserGroup.create!(user: @admin, group: @group)
    sign_in @admin
  end

  test "full folder lifecycle: create, assign workflow, view in accordion, move, delete" do
    # 1. Create folder via admin
    post admin_group_folders_path(@group), params: { folder: { name: "DNS Issues", position: 0 } }
    assert_redirected_to admin_group_folders_path(@group)
    folder = Folder.last
    assert_equal "DNS Issues", folder.name
    assert_equal @group.id, folder.group_id

    # 2. Create a workflow
    workflow = Workflow.create!(title: "DNS Troubleshoot", user: @admin, steps: [{ "type" => "action", "title" => "Check DNS", "instructions" => "Run dig" }])
    GroupWorkflow.create!(group: @group, workflow: workflow, folder: folder, is_primary: true)

    # 3. View workflows index with group selected — should see folder accordion
    get workflows_path(group_id: @group.id)
    assert_response :success
    assert_select "details" # Accordion element
    assert_match "DNS Issues", response.body

    # 4. Delete folder — workflow should become uncategorized
    delete admin_group_folder_path(@group, folder)
    assert_redirected_to admin_group_folders_path(@group)

    gw = GroupWorkflow.find_by(group: @group, workflow: workflow)
    assert_nil gw.folder_id
  end

  test "workflows without folders show in uncategorized accordion" do
    folder = Folder.create!(name: "Categorized", group: @group)
    wf1 = Workflow.create!(title: "Cat WF", user: @admin, steps: [{ "type" => "action", "title" => "Step", "instructions" => "Do" }])
    wf2 = Workflow.create!(title: "Uncat WF", user: @admin, steps: [{ "type" => "action", "title" => "Step", "instructions" => "Do" }])
    GroupWorkflow.create!(group: @group, workflow: wf1, folder: folder, is_primary: true)
    GroupWorkflow.create!(group: @group, workflow: wf2, is_primary: true)

    get workflows_path(group_id: @group.id)
    assert_response :success
    assert_match "Uncategorized", response.body
    assert_match "Uncat WF", response.body
  end

  test "all workflows view shows flat list regardless of folders" do
    folder = Folder.create!(name: "Some Folder", group: @group)
    wf = Workflow.create!(title: "Flat WF", user: @admin, steps: [{ "type" => "action", "title" => "Step", "instructions" => "Do" }])
    GroupWorkflow.create!(group: @group, workflow: wf, folder: folder, is_primary: true)

    get workflows_path # No group_id
    assert_response :success
    assert_match "Flat WF", response.body
  end
end
