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

    # 2. Create a workflow with AR steps
    workflow = Workflow.create!(title: "DNS Troubleshoot", user: @admin)
    Steps::Action.create!(workflow: workflow, position: 0, title: "Check DNS")
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
    wf1 = Workflow.create!(title: "Cat WF", user: @admin)
    Steps::Action.create!(workflow: wf1, position: 0, title: "Step")
    wf2 = Workflow.create!(title: "Uncat WF", user: @admin)
    Steps::Action.create!(workflow: wf2, position: 0, title: "Step")
    GroupWorkflow.create!(group: @group, workflow: wf1, folder: folder, is_primary: true)
    GroupWorkflow.create!(group: @group, workflow: wf2, is_primary: true)

    get workflows_path(group_id: @group.id)
    assert_response :success
    assert_match "Uncategorized", response.body
    assert_match "Uncat WF", response.body
  end

  test "all workflows view shows flat list regardless of folders" do
    folder = Folder.create!(name: "Some Folder", group: @group)
    wf = Workflow.create!(title: "Flat WF", user: @admin)
    Steps::Action.create!(workflow: wf, position: 0, title: "Step")
    GroupWorkflow.create!(group: @group, workflow: wf, folder: folder, is_primary: true)

    get workflows_path # No group_id
    assert_response :success
    assert_match "Flat WF", response.body
  end
  # The Uncategorized bucket used to be a second, hand-written copy of the
  # folder accordion markup. It drifted: its <summary> carried the class
  # "folder-accordion__header", which no stylesheet defines, so it lost the
  # flex row AND the ::-webkit-details-marker suppression — the native
  # disclosure triangle showed through and the contents stacked vertically.
  # These tests pin the two accordions to one shape.
  test "uncategorized bucket renders the same accordion structure as a named folder" do
    folder = Folder.create!(group: @group, name: "Email Issues", position: 0)

    filed = Workflow.create!(title: "Filed Flow", user: @admin)
    GroupWorkflow.create!(group: @group, workflow: filed, folder: folder, is_primary: true)

    loose = Workflow.create!(title: "Loose Flow", user: @admin)
    GroupWorkflow.create!(group: @group, workflow: loose, folder: nil, is_primary: true)

    get workflows_path(group_id: @group.id)
    assert_response :success

    # Two accordions, both built the same way.
    assert_select "details.folder-accordion", count: 2
    assert_select "details.folder-accordion > summary.folder-accordion__summary", count: 2

    # The class that caused the bug must not come back.
    assert_select ".folder-accordion__header", count: 0

    # Both bodies use the styled list, not a bare <ul>.
    assert_select "details.folder-accordion .folder-accordion__body ul.wf-list", count: 2
  end

  test "uncategorized bucket keeps its own icon, italic name and open state" do
    loose = Workflow.create!(title: "Loose Flow", user: @admin)
    GroupWorkflow.create!(group: @group, workflow: loose, folder: nil, is_primary: true)
    Folder.create!(group: @group, name: "Email Issues", position: 0)

    get workflows_path(group_id: @group.id)
    assert_response :success

    # Sharing the partial must not flatten the two intentional differences:
    # Uncategorized is a virtual bucket and should still read as one.
    assert_select "details.folder-accordion[open]", count: 1
    assert_select "details.folder-accordion[open] summary span.italic", text: "Uncategorized"
    assert_select "details.folder-accordion:not([open]) summary span", text: "Email Issues"
  end
end
