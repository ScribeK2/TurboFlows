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
    # answer_type: a Question without one is a READINESS_CODES finding, and publish asks.
    q1 = Steps::Question.create!(workflow: @workflow, position: 0, title: "Question 1", question: "What is your name?", answer_type: "text")
    r1 = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q1, target_step: r1, position: 0)
    @workflow.update_column(:start_step_id, q1.id)
    @public_workflow = Workflow.create!(
      title: "Public Workflow",
      description: "A Global workflow",
      user: @editor
    )
    q2 = Steps::Question.create!(workflow: @public_workflow, position: 0, title: "Question 1", question: "What is your name?", answer_type: "text")
    r2 = Steps::Resolve.create!(workflow: @public_workflow, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q2, target_step: r2, position: 0)
    @public_workflow.update_column(:start_step_id, q2.id)
    file_in_global(@public_workflow)
    sign_in @editor
  end

  test "should get index" do
    get workflows_path

    assert_response :success
  end

  # Global replaced the Public flag; the list says which workflows everyone can see.
  test "index marks a Global workflow with a Global badge, and only that one" do
    get workflows_path

    public_row = css_select("li.wf-list-item").find { it.text.include?(@public_workflow.title) }
    own_row = css_select("li.wf-list-item").find { it.text.include?(@workflow.title) }
    assert(public_row.css(".badge").any? { it.text.strip == "Global" })
    assert_not(own_row.css(".badge").any? { it.text.strip == "Global" })
  end

  test "index title opens the builder in edit for the owner" do
    get workflows_path

    assert_select ".wf-list-item__title[href=?]", workflow_path(@workflow, edit: true)
    assert_select ".wf-list-item__actions a", text: "View", count: 0
    assert_select ".wf-list-item__actions a", text: "Edit", count: 0
  end

  test "index offers Run only on published workflows" do
    draft = Workflow.create!(title: "Still a draft", user: @editor, status: "draft", graph_mode: true)

    get workflows_path

    assert_select ".wf-list-item__title[href=?]", workflow_path(@workflow, edit: true)
    assert_select "form[action=?]", play_workflow_path(@workflow)
    assert_select "form[action=?]", play_workflow_path(draft), count: 0
  end

  test "index page-size control defaults to 24" do
    get workflows_path

    assert_select "select[name=?] option[selected=selected]", "per_page" do |options|
      assert_equal "24", options.first["value"]
    end
  end

  test "should get show" do
    get workflow_path(@workflow)

    assert_response :success
  end

  test "GET new does not create a draft" do
    assert_no_difference("Workflow.count") do
      get new_workflow_path
    end
    assert_redirected_to workflows_path
  end

  test "GET new is a no-op even when Turbo prefetches it" do
    assert_no_difference("Workflow.count") do
      get new_workflow_path, headers: { "X-Sec-Purpose" => "prefetch" }
    end
    assert_redirected_to workflows_path
  end

  test "GET new redirects to an existing blank draft without creating another" do
    existing = Workflow.create!(title: "Untitled Workflow", user: @editor, status: "draft", graph_mode: true)

    assert_no_difference("Workflow.count") do
      get new_workflow_path
    end
    assert_redirected_to workflow_path(existing, edit: true)
  end

  test "POST create without params starts a draft and opens the builder" do
    assert_difference("Workflow.count", 1) do
      post workflows_path
    end
    workflow = Workflow.last
    assert_equal "draft", workflow.status
    assert_equal "Untitled Workflow", workflow.title
    assert_redirected_to workflow_path(workflow, edit: true)
  end

  test "POST create without params reuses a blank draft instead of creating a duplicate" do
    existing = Workflow.create!(title: "Untitled Workflow", user: @editor, status: "draft", graph_mode: true)

    assert_no_difference("Workflow.count") do
      post workflows_path
    end
    assert_redirected_to workflow_path(existing, edit: true)
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

  # The only page this could render was a leftover form nothing links to; the
  # app's New Workflow button posts no params and never fails here.
  test "a create that fails validation returns to Workflows and says why" do
    assert_no_difference("Workflow.count") do
      post workflows_path, params: { workflow: { title: "" } }
    end

    assert_redirected_to workflows_path
    assert_match "Title can't be blank", flash[:alert]
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

  # The builder saves over JSON and Turbo Streams; an HTML update comes from a
  # form without JavaScript or a hand-made request. Its error branch rendered
  # :edit, which has no template.
  test "an HTML update that fails validation returns to the builder and says why" do
    patch workflow_path(@workflow), params: { workflow: { title: "" } }

    assert_redirected_to workflow_path(@workflow, edit: true)
    assert_match "Title can't be blank", flash[:alert]
    assert_predicate @workflow.reload.title, :present?
  end

  test "an HTML update from a stale page returns to the builder with the conflict" do
    patch workflow_path(@workflow), params: { workflow: { title: "Stale Edit", lock_version: @workflow.lock_version + 5 } }

    assert_redirected_to workflow_path(@workflow, edit: true)
    assert_match "modified by another user", flash[:alert]
    assert_not_equal "Stale Edit", @workflow.reload.title
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
      post workflows_path
    end
    assert_redirected_to workflow_path(Workflow.last, edit: true)
  end

  test "editor should be able to create workflows" do
    sign_in @editor
    assert_difference("Workflow.count", 1) do
      post workflows_path
    end
    assert_redirected_to workflow_path(Workflow.last, edit: true)
  end

  test "user should not be able to create workflows" do
    sign_in @user
    assert_no_difference("Workflow.count") do
      post workflows_path
    end

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
      user: @admin
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
      user: @editor
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
      user: @admin
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

    # Assign one to the test group
    GroupWorkflow.create!(group: group, workflow: workflow_in_group, is_primary: true)

    # Assign the other to a group this editor is not in
    elsewhere = Group.create!(name: "Elsewhere")
    GroupWorkflow.create!(group: elsewhere, workflow: workflow_outside, is_primary: true)

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
    # An editor may file only into groups they reach (Group.assignable_ids_for).
    UserGroup.create!(user: @editor, group: group)

    sign_in @editor
    assert_difference("Workflow.count", 1) do
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

    GroupWorkflow.create!(group: group1, workflow: @workflow, is_primary: true)
    # An editor may add or remove only groups they reach (Group.assignable_ids_for).
    [group1, group2].each { UserGroup.create!(user: @editor, group: it) }

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

    workflow1 = Workflow.create!(title: "Accessible Workflow", user: @editor)
    workflow2 = Workflow.create!(title: "Inaccessible Workflow", user: @editor)

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

  # ===========================================================================
  # Backend Action Tests (publish, variables)
  # ===========================================================================

  test "publish with valid graph succeeds" do
    sign_in @editor
    # @workflow already has Q1 -> Done (Resolve) from setup
    file_in_global(@workflow)
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

    # edit=true: a failed publish leaves the builder in edit mode. Dropping it
    # swapped the header for Edit/Run Scenario/Export and took the add-step control
    # away, so the user was told to fix something and lost the tools to do it.
    assert_redirected_to workflow_path(bad_wf, edit: true)
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
    10.times { |i| Workflow.create!(title: "Sizing #{i}", user: @editor, status: "published") }

    get workflows_path(per_page: 6)
    assert_equal 6, rendered_workflow_count

    get workflows_path(per_page: 12)
    assert_operator rendered_workflow_count, :>, 6
  end

  test "index pagination is a three-zone bar with the summary outside the nav" do
    sign_in @editor
    10.times { |i| Workflow.create!(title: "Zoning #{i}", user: @editor, status: "published") }

    get workflows_path(per_page: 6)

    assert_response :success
    # The summary sits in the bar's left zone, not inside the nav — otherwise it
    # rides along with the numbered buttons and pushes them off true centre.
    assert_select ".pagination-bar > .pagination-bar__summary"
    assert_select "nav.pagination .pagination__summary", count: 0
    assert_select ".pagination-bar > nav.pagination"
    assert_select ".pagination-bar > .pagination-bar__per-page"
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

  # An editor saw "All Workflows 0" in the sidebar and, directly beneath it,
  # "Uncategorized 12" — then clicking Uncategorized showed "No workflows". The
  # count came from every GroupWorkflow row in the group, regardless of who was
  # looking. Found by walking the app as an editor.
  test "a group count matches the list that group opens" do
    editor = User.create!(email: "grp-ed-#{SecureRandom.hex(4)}@example.com",
                          password: "password123!", password_confirmation: "password123!", role: "editor")
    owner = User.create!(email: "grp-own-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    group = Group.create!(name: "Hidden Group #{SecureRandom.hex(3)}")
    hidden = Workflow.create!(title: "Not for the editor", user: owner, status: "published")
    hidden.groups << group

    assert_not_includes Workflow.visible_to(editor), hidden,
                        "precondition: this editor cannot see the workflow"

    sign_in editor
    get workflows_path(group_id: group.id)

    assert_response :success

    # This group's own row. Other groups legitimately have their own counts, so
    # the assertion has to be about the one whose workflow is hidden.
    row = css_select("a[href*='group_id=#{group.id}']").first

    assert row, "expected the group to appear in the sidebar"
    badge = row.css(".badge").first

    assert_nil badge,
               "the group holds nothing this editor can open, so it must not " \
               "advertise a count: got #{badge&.text&.strip.inspect}"

    # And the list agrees.
    assert_no_match(/#{Regexp.escape(hidden.title)}/, response.body)
  end

  # -- Slice 1: the Drafts tab is scoped like its siblings ----------------------
  #
  # `workflows_filter.rb` hardcoded `@user.workflows.drafts` for every role, so
  # the Drafts tab sat in a strip whose other tabs were org-wide while it showed
  # only your own. An admin saw "No workflows" against 23 real drafts, the
  # sidebar count flipped to 0, and /admin/data_health reported the true total
  # on another page.

  test "the drafts tab shows every draft to an admin" do
    admin = User.create!(email: "d-admin-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "admin")
    other = User.create!(email: "d-editor-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    theirs = Workflow.create!(title: "Draft belonging to a colleague", user: other, status: "draft")

    sign_in admin
    get workflows_path(status: "draft", per_page: 100)

    assert_response :success
    assert_match theirs.title, response.body,
                 "an admin must be able to see the drafts they are responsible for"
  end

  test "the drafts tab shows an editor only their own" do
    editor = User.create!(email: "d-mine-#{SecureRandom.hex(4)}@example.com",
                          password: "password123!", password_confirmation: "password123!", role: "editor")
    other = User.create!(email: "d-theirs-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    mine = Workflow.create!(title: "My own draft", user: editor, status: "draft")
    theirs = Workflow.create!(title: "Colleague unpublished draft", user: other, status: "draft")

    sign_in editor
    get workflows_path(status: "draft", per_page: 100)

    assert_response :success
    assert_match mine.title, response.body
    assert_no_match(/#{Regexp.escape(theirs.title)}/, response.body,
                    "a draft is unpublished work; group membership does not share it")
  end

  test "an empty drafts tab says the filter is empty, not the library" do
    admin = User.create!(email: "d-empty-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "admin")
    Workflow.drafts.destroy_all

    sign_in admin
    get workflows_path(status: "draft")

    assert_response :success
    assert_no_match(/Get started by creating a new workflow/, response.body,
                    "a filtered view finding nothing must not claim the library is empty")
    assert_match(/No drafts/i, response.body)
  end

  private

  # Only the flat workflow list — "ul li" would also pick up the group sidebar.
  def rendered_workflow_count
    css_select("li.wf-list-item").size
  end
end
