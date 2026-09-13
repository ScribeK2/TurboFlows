require "test_helper"

module Teams
  # Curating a team's featured workflows (spec 2026-09-13-group-featured-workflows).
  class FeaturedWorkflowsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tag = SecureRandom.hex(3)
      @team = Group.create!(name: "Billing #{@tag}")
      @other_team = Group.create!(name: "Sales #{@tag}")
      @manager = person("manager", "user")
      GroupManager.create!(group: @team, user: @manager)
      @author = person("author", "editor")
      @invoices = filed("Invoices", @team)
      @refunds = filed("Refunds", @team)
      @quotes = filed("Quotes", @other_team)
      sign_in @manager
    end

    test "a manager features a workflow the team can see, and the card and flash come back" do
      post team_featured_workflows_path(@team), params: { workflow_id: @invoices.id }, as: :turbo_stream

      row = @team.featured_workflows.sole
      assert_equal [@invoices, @manager, 0], [row.workflow, row.added_by, row.position]
      assert_select "turbo-stream[action='replace'][target='team-featured']"
      assert_select "turbo-stream[action='update'][target='flash']"
      assert_includes response.body, "Featured Invoices #{@tag} for #{@team.name}."
    end

    test "a new feature goes to the bottom of the list" do
      feature(@invoices, position: 0)

      post team_featured_workflows_path(@team), params: { workflow_id: @refunds.id }, as: :turbo_stream

      assert_equal [@invoices, @refunds], @team.featured_workflows.ordered.map(&:workflow)
    end

    test "featuring a workflow the team can't see is refused with the reason, and nothing is saved" do
      assert_no_difference "GroupFeaturedWorkflow.count" do
        post team_featured_workflows_path(@team), params: { workflow_id: @quotes.id }, as: :turbo_stream
      end

      assert_includes response.body, "isn&#39;t visible to #{@team.name}&#39;s members"
    end

    test "the ninth is refused with the limit" do
      Array.new(GroupFeaturedWorkflow::MAX_PER_GROUP) { |i| feature(filed("Kit #{i}", @team), position: i) }

      assert_no_difference "GroupFeaturedWorkflow.count" do
        post team_featured_workflows_path(@team), params: { workflow_id: @invoices.id }, as: :turbo_stream
      end

      assert_includes response.body, "A team can feature up to 8 workflows"
    end

    test "the search offers what members can see and isn't featured yet, whether or not the manager can open it" do
      feature(@refunds, position: 0)

      get team_featured_workflows_path(@team, q: @tag)

      assert_select "turbo-frame#team-featured-search button[aria-label=?]", "Feature Invoices #{@tag} for #{@team.name}"
      assert_select "turbo-frame#team-featured-search button[aria-label*=?]", "Refunds #{@tag}", count: 0
      assert_select "turbo-frame#team-featured-search button[aria-label*=?]", "Quotes #{@tag}", count: 0
    end

    test "remove takes a workflow off the list" do
      row = feature(@invoices, position: 0)

      delete team_featured_workflow_path(@team, row), as: :turbo_stream

      assert_not GroupFeaturedWorkflow.exists?(row.id)
      assert_includes response.body, "Removed Invoices #{@tag} from #{@team.name}."
    end

    test "move up and move down swap neighbours, and the ends stay put" do
      first = feature(@invoices, position: 0)
      second = feature(@refunds, position: 1)

      patch move_team_featured_workflow_path(@team, second), params: { direction: "up" }, as: :turbo_stream
      assert_equal [@refunds, @invoices], @team.featured_workflows.ordered.map(&:workflow)

      patch move_team_featured_workflow_path(@team, second), params: { direction: "up" }, as: :turbo_stream
      assert_equal [@refunds, @invoices], @team.featured_workflows.ordered.map(&:workflow)

      patch move_team_featured_workflow_path(@team, first), params: { direction: "down" }, as: :turbo_stream
      assert_equal [@refunds, @invoices], @team.featured_workflows.ordered.map(&:workflow)
    end

    test "reorder saves the dragged order" do
      first = feature(@invoices, position: 0)
      second = feature(@refunds, position: 1)

      patch reorder_team_featured_workflows_path(@team), params: { featured_ids: [second.id, first.id] }, as: :json

      assert_response :ok
      assert_equal [@refunds, @invoices], @team.featured_workflows.ordered.map(&:workflow)
    end

    test "a row from another team can't be removed or moved through this team's address" do
      foreign = GroupFeaturedWorkflow.create!(group: @other_team, workflow: @quotes, position: 0)
      GroupFeaturedWorkflow.create!(group: @other_team, workflow: filed("Leads", @other_team), position: 1)

      delete team_featured_workflow_path(@team, foreign), as: :turbo_stream
      assert_response :not_found
      assert GroupFeaturedWorkflow.exists?(foreign.id)

      # A 404 is rendered above the session middleware, so the sign-in cookie
      # never reached the client; sign in again for the second attempt.
      sign_in @manager
      patch move_team_featured_workflow_path(@team, foreign), params: { direction: "down" }, as: :turbo_stream
      assert_response :not_found
      assert_equal 0, foreign.reload.position
    end

    test "a reorder naming another team's row leaves that row where it was" do
      mine = feature(@invoices, position: 0)
      foreign = GroupFeaturedWorkflow.create!(group: @other_team, workflow: @quotes, position: 3)

      patch reorder_team_featured_workflows_path(@team), params: { featured_ids: [foreign.id, mine.id] }, as: :json

      assert_response :ok
      assert_equal 3, foreign.reload.position
      assert_equal 1, mine.reload.position
    end

    test "someone who can't curate the team is turned away from every action, the same as a missing team" do
      row = feature(@invoices, position: 0)
      sign_out :user
      outsider = person("outsider", "user")
      GroupManager.create!(group: @other_team, user: outsider)
      sign_in outsider

      [@team.id, 0].each do |team_id|
        get team_featured_workflows_path(team_id, q: @tag)
        assert_redirected_to root_path
        post team_featured_workflows_path(team_id), params: { workflow_id: @refunds.id }
        assert_redirected_to root_path
        delete team_featured_workflow_path(team_id, row)
        assert_redirected_to root_path
        patch move_team_featured_workflow_path(team_id, row), params: { direction: "down" }
        assert_redirected_to root_path
        patch reorder_team_featured_workflows_path(team_id), params: { featured_ids: [row.id] }, as: :json
        assert_redirected_to root_path
      end

      assert_equal [@invoices], @team.featured_workflows.map(&:workflow)
    end

    test "the HTML fallback returns to the team page" do
      post team_featured_workflows_path(@team), params: { workflow_id: @invoices.id }

      assert_redirected_to team_path(@team)
    end

    test "the team page offers Move up, Move down, Remove and the search" do
      feature(@invoices, position: 0)
      feature(@refunds, position: 1)

      get team_path(@team)

      assert_select "#team-featured [data-controller='sortable-list'][data-sortable-list-param-value='featured_ids']"
      assert_select "#team-featured button[aria-label=?]", "Move Invoices #{@tag} up", count: 0
      assert_select "#team-featured button[aria-label=?]", "Move Invoices #{@tag} down"
      assert_select "#team-featured button[aria-label=?]", "Move Refunds #{@tag} up"
      assert_select "#team-featured button[aria-label=?]", "Move Refunds #{@tag} down", count: 0
      assert_select "#team-featured button[aria-label=?]", "Remove Invoices #{@tag} from #{@team.name}"
      assert_select "#team-featured input[aria-label=?]", "Find workflows to feature for #{@team.name}"
      assert_select "#team-featured [autofocus]", count: 0
    end

    test "a drag asked for as a stream answers with the card, its Move buttons following the new order" do
      first = feature(@invoices, position: 0)
      second = feature(@refunds, position: 1)

      patch reorder_team_featured_workflows_path(@team), params: { featured_ids: [second.id, first.id], q: @tag },
                                                         as: :turbo_stream

      assert_response :ok
      assert_equal [@refunds, @invoices], @team.featured_workflows.ordered.map(&:workflow)
      assert_select "turbo-stream[action='replace'][target='team-featured'] template" do
        assert_select "button[aria-label=?]", "Move Refunds #{@tag} up", count: 0
        assert_select "button[aria-label=?]", "Move Refunds #{@tag} down"
        assert_select "button[aria-label=?]", "Move Invoices #{@tag} up"
        assert_select "button[aria-label=?]", "Move Invoices #{@tag} down", count: 0
        assert_select "[data-sortable-list-query-value=?]", @tag
        assert_select "[autofocus]", count: 0
      end
    end

    test "a drag asked for as JSON still answers with an empty 200" do
      first = feature(@invoices, position: 0)
      second = feature(@refunds, position: 1)

      patch reorder_team_featured_workflows_path(@team), params: { featured_ids: [second.id, first.id] }, as: :json

      assert_response :ok
      assert_empty response.body
    end

    # Move replaces the whole card, so without autofocus a keyboard user's focus
    # falls to the page. It stays on the row that moved: its button the same way,
    # or the other one once the row reaches an end.
    test "after Move the moved row's button keeps focus, switching direction at an end" do
      feature(@invoices, position: 0)
      feature(@refunds, position: 1)
      credits = feature(filed("Credits", @team), position: 2)

      patch move_team_featured_workflow_path(@team, credits), params: { direction: "up" }, as: :turbo_stream
      assert_select "turbo-stream[action='replace'][target='team-featured'] template" do
        assert_select "[autofocus]", count: 1
        assert_select "button[autofocus][aria-label=?]", "Move Credits #{@tag} up"
      end

      patch move_team_featured_workflow_path(@team, credits), params: { direction: "up" }, as: :turbo_stream
      assert_select "turbo-stream[action='replace'][target='team-featured'] template" do
        assert_select "[autofocus]", count: 1
        assert_select "button[autofocus][aria-label=?]", "Move Credits #{@tag} down"
      end
    end

    # Two Features of the same workflow at once. Here the other request's row
    # lands inside the failed save's savepoint and rolls back with it, so this
    # asserts the answer, not the row; in production that row is committed.
    test "a Feature that loses the race at the unique index still answers as featured" do
      raced = stage_a_racing_feature(@invoices, after: 'SELECT 1 AS one FROM "group_featured_workflows"') do
        post team_featured_workflows_path(@team), params: { workflow_id: @invoices.id }, as: :turbo_stream
      end

      assert raced, "the uniqueness check never ran, so no race was staged"
      assert_response :success
      assert_includes response.body, "Featured Invoices #{@tag} for #{@team.name}."
    end

    # The other row can also land before the save starts, and then the uniqueness
    # validation refuses it.
    test "a Feature that loses the race at the uniqueness check answers as featured, not with the model's message" do
      raced = stage_a_racing_feature(@invoices, after: 'SELECT MAX("group_featured_workflows"."position")') do
        post team_featured_workflows_path(@team), params: { workflow_id: @invoices.id }, as: :turbo_stream
      end

      assert raced, "the position lookup never ran, so no race was staged"
      assert_response :success
      assert_equal 1, @team.featured_workflows.where(workflow: @invoices).count
      assert_includes response.body, "Featured Invoices #{@tag} for #{@team.name}."
      assert_includes response.body, "Remove Invoices #{@tag} from #{@team.name}"
      assert_not_includes response.body, "has already been taken"
    end

    private

    # Stands in for a second request featuring the same workflow: writes that row
    # the moment the first query starting with `after` has run. Returns whether it
    # ran, so a test can tell a staged race from one that never happened.
    def stage_a_racing_feature(workflow, after:, &)
      raced = false
      write_the_other_row = lambda do |*, payload|
        next if raced || !payload[:sql].start_with?(after)

        raced = true
        GroupFeaturedWorkflow.insert_all([{ group_id: @team.id, workflow_id: workflow.id, position: 0,
                                            created_at: Time.current, updated_at: Time.current }])
      end

      ActiveSupport::Notifications.subscribed(write_the_other_row, "sql.active_record", &)
      raced
    end

    def person(label, role)
      User.create!(email: "curate-#{label}-#{@tag}@example.com", password: "password123!",
                   password_confirmation: "password123!", role:)
    end

    def filed(title, group)
      workflow = Workflow.create!(title: "#{title} #{@tag}", user: @author, status: "published")
      GroupWorkflow.create!(group:, workflow:, is_primary: true)
      workflow
    end

    def feature(workflow, position:)
      GroupFeaturedWorkflow.create!(group: @team, workflow:, added_by: @manager, position:)
    end
  end
end
