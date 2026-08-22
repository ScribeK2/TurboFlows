require "test_helper"

class WorkflowsControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Create users with different roles (using unique emails)
    @admin = User.create!(
      email: "admin-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @user = User.create!(
      email: "user-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    @workflow = Workflow.create!(
      title: "Test Workflow",
      description: "A test workflow",
      user: @editor
    )
    q1 = Steps::Question.create!(workflow: @workflow, position: 0, title: "Question 1", question: "What is your name?")
    r1 = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q1, target_step: r1, position: 0)
    @workflow.update_column(:start_step_id, q1.id)
    @public_workflow = Workflow.create!(
      title: "Public Workflow",
      description: "A public workflow",
      user: @editor,
      is_public: true
    )
    q2 = Steps::Question.create!(workflow: @public_workflow, position: 0, title: "Question 1", question: "What is your name?")
    r2 = Steps::Resolve.create!(workflow: @public_workflow, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q2, target_step: r2, position: 0)
    @public_workflow.update_column(:start_step_id, q2.id)
    sign_in @editor
  end

  test "should get index" do
    get workflows_path

    assert_response :success
  end

  test "should get show" do
    get workflow_path(@workflow)

    assert_response :success
  end

  test "should get new" do
    assert_difference("Workflow.count", 1) do
      get new_workflow_path
    end
    workflow = Workflow.last
    assert_equal "draft", workflow.status
    assert_redirected_to workflow_path(workflow, edit: true)
  end

  test "new reuses existing blank draft instead of creating duplicate" do
    # First visit creates a draft
    get new_workflow_path
    first_draft = Workflow.last

    # Second visit reuses same draft
    assert_no_difference("Workflow.count") do
      get new_workflow_path
    end
    assert_redirected_to workflow_path(first_draft, edit: true)
  end

  test "should create workflow" do
    assert_difference("Workflow.count") do
      post workflows_path, params: {
        workflow: {
          title: "New Workflow",
          description: "New description"
        }
      }
    end

    assert_redirected_to workflow_path(Workflow.last)
    assert_equal "Workflow was successfully created.", flash[:notice]
  end

  test "should get edit" do
    get edit_workflow_path(@workflow)

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "should update workflow" do
    patch workflow_path(@workflow), params: {
      workflow: {
        title: "Updated Title",
        description: "Updated description"
      }
    }

    assert_redirected_to workflow_path(@workflow)
    @workflow.reload

    assert_equal "Updated Title", @workflow.title
    assert_equal "Updated description", @workflow.description.to_plain_text
  end

  test "should update workflow with title" do
    patch workflow_path(@workflow), params: {
      workflow: {
        title: "Updated Title"
      }
    }

    assert_redirected_to workflow_path(@workflow)
    @workflow.reload

    assert_equal "Updated Title", @workflow.title
    assert_equal 2, @workflow.steps.count
  end

  test "should update workflow with is_public flag" do
    patch workflow_path(@workflow), params: {
      workflow: {
        title: @workflow.title,
        is_public: true
      }
    }

    assert_redirected_to workflow_path(@workflow)
    @workflow.reload

    assert_predicate @workflow, :is_public?
  end

  test "should destroy workflow" do
    assert_difference("Workflow.count", -1) do
      delete workflow_path(@workflow)
    end

    assert_redirected_to workflows_path
  end

  test "should require authentication" do
    sign_out @editor
    get workflows_path

    assert_redirected_to new_user_session_path
  end

  # Authorization Tests
  test "index should show workflows visible to user based on role" do
    # Editor should see own workflows + public workflows
    sign_in @editor
    get workflows_path

    assert_response :success
    assert_select "h1", text: /Workflows/
    # Verify editor sees their workflow
    assert_match @workflow.title, response.body

    # Regular user is redirected to /play
    sign_in @user
    get workflows_path

    assert_redirected_to play_path
  end

  test "admin should be able to view any workflow" do
    sign_in @admin
    get workflow_path(@workflow)

    assert_response :success
  end

  test "editor should be able to view own workflow" do
    sign_in @editor
    get workflow_path(@workflow)

    assert_response :success
  end

  test "editor should be able to view public workflow" do
    sign_in @editor
    get workflow_path(@public_workflow)

    assert_response :success
  end

  test "user should be redirected to play from public workflow" do
    sign_in @user
    get workflow_path(@public_workflow)

    assert_redirected_to play_path
  end

  test "user should not be able to view private workflow" do
    sign_in @user
    get workflow_path(@workflow)

    assert_redirected_to play_path
  end

  test "admin should be able to create workflows" do
    sign_in @admin
    assert_difference("Workflow.count", 1) do
      get new_workflow_path
    end
    assert_redirected_to workflow_path(Workflow.last, edit: true)
  end

  test "editor should be able to create workflows" do
    sign_in @editor
    assert_difference("Workflow.count", 1) do
      get new_workflow_path
    end
    assert_redirected_to workflow_path(Workflow.last, edit: true)
  end

  test "user should not be able to create workflows" do
    sign_in @user
    get new_workflow_path

    assert_redirected_to play_path
  end

  test "admin should be able to edit any workflow" do
    sign_in @admin
    get edit_workflow_path(@workflow)

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "editor should be able to edit own workflow" do
    sign_in @editor
    get edit_workflow_path(@workflow)

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "editor should not be able to edit other user's workflow" do
    other_workflow = Workflow.create!(
      title: "Other Workflow",
      user: @admin,
      is_public: false
    )
    sign_in @editor
    get edit_workflow_path(other_workflow)

    assert_redirected_to workflows_path
    assert_equal "You don't have permission to edit this workflow.", flash[:alert]
  end

  test "user should not be able to edit workflows" do
    sign_in @user
    get edit_workflow_path(@public_workflow)

    assert_redirected_to play_path
  end

  test "admin should be able to delete any workflow" do
    workflow_to_delete = Workflow.create!(
      title: "To Delete",
      user: @editor,
      is_public: false
    )
    sign_in @admin
    assert_difference("Workflow.count", -1) do
      delete workflow_path(workflow_to_delete)
    end
  end

  test "editor should be able to delete own workflow" do
    sign_in @editor
    assert_difference("Workflow.count", -1) do
      delete workflow_path(@workflow)
    end
  end

  test "editor should not be able to delete other user's workflow" do
    other_workflow = Workflow.create!(
      title: "Other Workflow",
      user: @admin,
      is_public: false
    )
    sign_in @editor
    assert_no_difference("Workflow.count") do
      delete workflow_path(other_workflow)
    end
    assert_redirected_to workflows_path
    assert_equal "You don't have permission to delete this workflow.", flash[:alert]
  end

  test "user should not be able to delete workflows" do
    sign_in @user
    assert_no_difference("Workflow.count") do
      delete workflow_path(@public_workflow)
    end
    assert_redirected_to play_path
  end

  test "admin should be able to export any workflow" do
    sign_in @admin
    get workflow_export_path(@workflow)

    assert_response :success
    assert_match(%r{application/json}, response.content_type)
  end

  test "user should be able to export public workflow" do
    sign_in @user
    get workflow_export_path(@public_workflow)

    assert_response :success
  end

  test "user should not be able to export private workflow" do
    sign_in @user
    get workflow_export_path(@workflow)

    assert_redirected_to workflows_path
    assert_equal "You don't have permission to view this workflow.", flash[:alert]
  end

  test "should export workflow as PDF" do
    sign_in @editor
    get pdf_workflow_export_path(@workflow)

    assert_response :success
    assert_match(%r{application/pdf}, response.content_type)
  end

  # Group-related tests
  test "should filter workflows by group" do
    group = Group.create!(name: "Test Group")
    workflow_in_group = Workflow.create!(title: "In Group", user: @editor)
    workflow_outside = Workflow.create!(title: "Outside Exclusive", user: @editor)

    # Remove Uncategorized assignments and assign to specific groups
    workflow_in_group.group_workflows.destroy_all
    workflow_outside.group_workflows.destroy_all

    # Assign one to the test group
    GroupWorkflow.create!(group: group, workflow: workflow_in_group, is_primary: true)

    # Assign the other to Uncategorized explicitly (simulating manual assignment)
    uncategorized = Group.uncategorized
    GroupWorkflow.create!(group: uncategorized, workflow: workflow_outside, is_primary: true)

    # Give user access to the test group
    UserGroup.create!(user: @editor, group: group)

    sign_in @editor
    get workflows_path, params: { group_id: group.id }

    assert_response :success
    assert_match "In Group", response.body
    # Should not show workflow from different group when filtering
    assert_no_match "Outside Exclusive", response.body
  end

  test "should show all workflows when no group selected" do
    Group.create!(name: "Test Group")
    Workflow.create!(title: "Workflow 1", user: @editor)
    Workflow.create!(title: "Workflow 2", user: @editor)

    sign_in @editor
    get workflows_path

    assert_response :success
    assert_match "Workflow 1", response.body
    assert_match "Workflow 2", response.body
  end

  test "should create workflow with group assignment" do
    group = Group.create!(name: "Test Group")

    sign_in @editor
    assert_difference("Workflow.count", 1) do
      # GroupWorkflow count increases by 1 for explicit group + possibly Uncategorized auto-assignment
      # Note: The after_create callback creates Uncategorized assignment when no groups exist,
      # but group_ids are processed AFTER the workflow is created, so it runs first.
      # This is expected behavior - we test that the explicit group is present.
      post workflows_path, params: {
        workflow: {
          title: "New Workflow",
          description: "New description",
          group_ids: [group.id]
        }
      }
    end

    workflow = Workflow.last

    assert_includes workflow.groups.map(&:id), group.id
    assert_predicate workflow.group_workflows.find_by(group: group), :is_primary?
  end

  test "should update workflow with group assignment" do
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")

    # Remove Uncategorized assignment
    @workflow.group_workflows.destroy_all
    GroupWorkflow.create!(group: group1, workflow: @workflow, is_primary: true)

    sign_in @editor
    patch workflow_path(@workflow), params: {
      workflow: {
        title: @workflow.title,
        group_ids: [group2.id]
      }
    }

    @workflow.reload

    assert_not_includes @workflow.groups.map(&:id), group1.id
    assert_includes @workflow.groups.map(&:id), group2.id
  end

  test "should not show workflows from inaccessible groups" do
    editor2 = User.create!(
      email: "editor2-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    accessible_group = Group.create!(name: "Accessible")
    inaccessible_group = Group.create!(name: "Inaccessible")

    workflow1 = Workflow.create!(title: "Accessible Workflow", user: @editor, is_public: false)
    workflow2 = Workflow.create!(title: "Inaccessible Workflow", user: @editor, is_public: false)

    # Remove Uncategorized assignments
    workflow1.group_workflows.destroy_all
    workflow2.group_workflows.destroy_all

    GroupWorkflow.create!(group: accessible_group, workflow: workflow1, is_primary: true)
    GroupWorkflow.create!(group: inaccessible_group, workflow: workflow2, is_primary: true)

    UserGroup.create!(group: accessible_group, user: editor2)

    sign_in editor2
    get workflows_path

    assert_response :success
    assert_match "Accessible Workflow", response.body
    assert_no_match "Inaccessible Workflow", response.body
  end

  test "should show accessible groups in sidebar" do
    accessible_group = Group.create!(name: "Accessible")
    Group.create!(name: "Inaccessible")

    UserGroup.create!(group: accessible_group, user: @editor)

    sign_in @editor
    get workflows_path

    assert_response :success
    assert_match "Accessible", response.body
    assert_no_match "Inaccessible", response.body
  end

  test "index with group_id should load folders for that group" do
    group = Group.create!(name: "Folder Index Group")
    UserGroup.create!(user: @editor, group: group)
    folder = Folder.create!(name: "DNS Folder", group: group)
    workflow = Workflow.create!(title: "DNS WF", user: @editor)
    GroupWorkflow.create!(group: group, workflow: workflow, folder: folder, is_primary: true)

    sign_in @editor
    get workflows_path(group_id: group.id)
    assert_response :success
    assert_match "DNS WF", response.body
  end

  test "admin should see all groups in sidebar" do
    Group.create!(name: "Group 1")
    Group.create!(name: "Group 2")

    sign_in @admin
    get workflows_path

    assert_response :success
    assert_match "Group 1", response.body
    assert_match "Group 2", response.body
  end

  test "GET new creates a draft workflow and redirects to builder" do
    sign_in @editor
    assert_difference("Workflow.count", 1) do
      get new_workflow_path
    end
    workflow = Workflow.last
    assert_equal "draft", workflow.status
    assert_equal "Untitled Workflow", workflow.title
    assert_redirected_to workflow_path(workflow, edit: true)
  end

  test "GET new reuses blank draft for same user" do
    sign_in @editor
    existing = Workflow.create!(title: "Untitled Workflow", user: @editor, status: "draft", graph_mode: true)

    assert_no_difference("Workflow.count") do
      get new_workflow_path
    end
    assert_redirected_to workflow_path(existing, edit: true)
  end

  # ===========================================================================
  # Backend Action Tests (sync_steps, publish, variables)
  # ===========================================================================

  test "sync_steps with valid data returns lock_version" do
    sign_in @editor
    draft = Workflow.create!(title: "Sync Draft", user: @editor, status: "draft")

    patch workflow_step_sync_path(draft), params: {
      steps: [
        { id: "u1", type: "question", title: "Q1", question: "What?", position: 0, transitions: [] },
        { id: "u2", type: "resolve", title: "Done", resolution_type: "success", position: 1, transitions: [] }
      ],
      start_node_uuid: "u1",
      lock_version: draft.lock_version
    }, as: :json

    assert_response :success
    json = response.parsed_body
    assert json["success"]
    assert_kind_of Integer, json["lock_version"]
  end

  test "sync_steps with stale lock_version returns 409" do
    sign_in @editor
    draft = Workflow.create!(title: "Stale Sync", user: @editor, status: "draft")

    patch workflow_step_sync_path(draft), params: {
      steps: [{ id: "u1", type: "action", title: "A1", transitions: [] }],
      start_node_uuid: "u1",
      lock_version: draft.lock_version + 99
    }, as: :json

    assert_response :conflict
    json = response.parsed_body
    assert_predicate json["error"], :present?
  end

  test "publish with valid graph succeeds" do
    sign_in @editor
    # @workflow already has Q1 -> Done (Resolve) from setup
    assert_difference("WorkflowVersion.count", 1) do
      post workflow_publishing_path(@workflow), params: { changelog: "Test publish" }
    end

    assert_redirected_to workflow_path(@workflow)
    @workflow.reload
    assert_equal "published", @workflow.status
    assert_not_nil @workflow.published_version
  end

  test "publish with invalid graph fails" do
    sign_in @editor
    bad_wf = Workflow.create!(title: "Bad Graph", user: @editor, status: "draft")
    # Only an Action step, no Resolve terminal
    a = Steps::Action.create!(workflow: bad_wf, position: 0, title: "Orphan Action")
    bad_wf.update_column(:start_step_id, a.id)

    assert_no_difference("WorkflowVersion.count") do
      post workflow_publishing_path(bad_wf)
    end

    assert_redirected_to workflow_path(bad_wf)
    assert_match(/Resolve/, flash[:alert])
  end

  test "variables returns Question step variables" do
    sign_in @editor
    get workflow_variables_path(@workflow), as: :json

    assert_response :success
    json = response.parsed_body
    assert_kind_of Array, json["variables"]
  end
  # --- Page-size control (index) ------------------------------------------

  test "index renders the page-size control with the allowlisted options" do
    sign_in @editor
    get workflows_path

    assert_response :success
    assert_select "select[name=?]", "per_page" do
      WorkflowsFilter::PER_PAGE_OPTIONS.each do |size|
        assert_select "option[value=?]", size.to_s
      end
    end
  end

  test "index page-size control marks the active size as selected" do
    sign_in @editor
    get workflows_path(per_page: 12)

    assert_response :success
    assert_select "select[name=?] option[selected=selected]", "per_page" do |options|
      assert_equal "12", options.first["value"]
    end
  end

  test "index honours per_page and limits the rendered list" do
    sign_in @editor
    10.times { |i| Workflow.create!(title: "Sizing #{i}", user: @editor, status: "published", is_public: true) }

    get workflows_path(per_page: 6)
    assert_equal 6, rendered_workflow_count

    get workflows_path(per_page: 12)
    assert_operator rendered_workflow_count, :>, 6
  end

  test "index page-size control renders even when results fit on one page" do
    sign_in @editor
    get workflows_path(per_page: 24)

    assert_response :success
    # The nav is correctly absent at a single page, but the control must remain
    # or there is no way back to a smaller size.
    assert_select "nav.pagination", false
    assert_select "select[name=?]", "per_page"
  end

  test "index preserves per_page across search, status and sort controls" do
    sign_in @editor
    get workflows_path(per_page: 12)

    assert_response :success
    assert_select "form.wf-toolbar__search input[name=?][value=?]", "per_page", "12"
    assert_select ".wf-status-tabs__tab[href*=?]", "per_page=12"
    assert_select ".wf-toolbar__sort option[value*=?]", "per_page=12"
  end

  test "index falls back to the default size for an off-allowlist per_page" do
    sign_in @editor
    get workflows_path(per_page: 999)

    assert_response :success
    assert_select "select[name=?] option[selected=selected]", "per_page" do |options|
      assert_equal WorkflowsFilter::DEFAULT_PER_PAGE.to_s, options.first["value"]
    end
  end

  private

  # Only the flat workflow list — "ul li" would also pick up the group sidebar.
  def rendered_workflow_count
    css_select("li.wf-list-item").size
  end
end
