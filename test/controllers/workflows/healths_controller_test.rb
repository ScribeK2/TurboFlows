# frozen_string_literal: true

require "test_helper"

module Workflows
  class HealthsControllerTest < ActionDispatch::IntegrationTest
    def setup
      Bullet.enable = false
      @editor = User.create!(
        email: "health-ed-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "editor"
      )
      @workflow = Workflow.create!(title: "Health Flow", user: @editor, status: "draft")
      sign_in @editor
    end

    def teardown
      Bullet.enable = true
    end

    test "show returns JSON health data for clean workflow" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      r = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Done", resolution_type: "success"
      )
      Transition.create!(step: q, target_step: r, position: 0)
      @workflow.update!(start_step: q)

      get workflow_health_path(@workflow, format: :json)

      assert_response :success
      json = response.parsed_body
      assert_includes json.keys, "issues"
      assert_includes json.keys, "summary"
      assert_includes json.keys, "clean"
      assert json["clean"]
    end

    test "show returns issues for broken workflow" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Done", resolution_type: "success"
      )
      @workflow.update!(start_step: q)

      get workflow_health_path(@workflow, format: :json)

      assert_response :success
      json = response.parsed_body
      assert_not json["clean"]
      assert_operator json["summary"]["total"], :>, 0
    end

    test "show requires authentication" do
      sign_out @editor
      get workflow_health_path(@workflow, format: :json)

      assert_response :unauthorized
    end

    test "show returns HTML health panel for clean workflow" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      r = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Done", resolution_type: "success"
      )
      Transition.create!(step: q, target_step: r, position: 0)
      @workflow.update!(start_step: q)

      get workflow_health_path(@workflow)

      assert_response :success
      assert_includes response.body, "All checks passing"
      assert_includes response.body, "builder-panel"
    end

    test "show returns HTML health panel with issues" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Done", resolution_type: "success"
      )
      @workflow.update!(start_step: q)

      get workflow_health_path(@workflow)

      assert_response :success
      assert_includes response.body, "Errors"
      assert_includes response.body, "No outgoing connections"
    end

    test "show returns error summary counts" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "", question: "What?", answer_type: "text"
      )
      r = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Done", resolution_type: "success"
      )
      Transition.create!(step: q, target_step: r, position: 0)
      @workflow.update!(start_step: q)

      get workflow_health_path(@workflow, format: :json)

      assert_response :success
      json = response.parsed_body
      summary = json["summary"]
      assert_kind_of Integer, summary["total"]
      assert_kind_of Integer, summary["errors"]
      assert_kind_of Integer, summary["warnings"]
      assert_equal summary["errors"] + summary["warnings"], summary["total"]
    end

    # Guards against reintroducing a latent collision, not an active one: the
    # panel used to gate "All required fields present" on
    # `message.include?("required")`, and GraphValidator's :no_terminal_nodes
    # finding reads "...at least one Resolve step is required." — but
    # WorkflowHealthCheck#classify_graph_finding already rewrites that finding
    # to "Workflow has no ending steps" before it ever reaches the panel, so
    # the substring never actually collided here (verified: this test passes
    # even against the pre-fix substring-matching code). It pins that a graph
    # with no terminal node — trivially reachable, just two steps that only
    # transition to each other — never suppresses this row, however either
    # side is implemented later.
    test "no terminal nodes does not suppress the required-fields passing check" do
      a = Steps::Action.create!(workflow: @workflow, uuid: SecureRandom.uuid, position: 0, title: "First")
      b = Steps::Action.create!(workflow: @workflow, uuid: SecureRandom.uuid, position: 1, title: "Second")
      Transition.create!(step: a, target_step: b, position: 0)
      Transition.create!(step: b, target_step: a, position: 0)
      @workflow.update!(start_step: a)

      get workflow_health_path(@workflow)

      assert_response :success
      assert_not_includes response.body, "All checks passing"
      assert_includes response.body, "All required fields present"
    end

    # Regression: a fresh Sub-Flow step has no target until the user picks one
    # ("Sub-flow target is required for publish" — Steps::SubFlow validates
    # presence only `on: :publish`, so an ordinary create via the builder saves
    # with a blank sub_flow_workflow_id). That message contains "sub-flow",
    # which the panel used to match to gate "No circular sub-flows" — so an
    # unpicked target silently hid a passing check about circularity, nothing
    # to do with the missing field.
    test "missing sub-flow target does not suppress the circular sub-flow passing check" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      r = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Done", resolution_type: "success"
      )
      Transition.create!(step: q, target_step: r, position: 0)
      @workflow.update!(start_step: q)

      sf = Steps::SubFlow.create!(workflow: @workflow, uuid: SecureRandom.uuid, position: 2, title: "Sub")
      assert_nil sf.sub_flow_workflow_id, "a freshly-added Sub-Flow step has no target yet"

      get workflow_health_path(@workflow)

      assert_response :success
      assert_not_includes response.body, "All checks passing"
      assert_includes response.body, "Sub-flow target is required for publish"
      assert_includes response.body, "No circular sub-flows"
    end

    # The two regressions above were both substring collisions: a message that
    # happens to contain "required" or "sub-flow" wrongly hid an unrelated
    # passing check. This pins the general fix — a message carrying either
    # trigger word, but a code outside the five the panel actually keys on,
    # must not suppress anything. WorkflowHealthCheck.call is stubbed because
    # no real validator produces this combination; the point is that the panel
    # no longer looks at `message` for these rows at all.
    test "passing checks key on code, not on message wording" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      r = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Done", resolution_type: "success"
      )
      Transition.create!(step: q, target_step: r, position: 0)
      @workflow.update!(start_step: q)

      synthetic = WorkflowHealthCheck::Result.new(
        issues: {
          q.uuid => [
            { severity: :warning, message: "A field on this step is required, unrelated to health codes",
              fixable: false, code: :some_other_code },
            { severity: :warning, message: "Nothing about sub-flow wiring is wrong here",
              fixable: false, code: :another_code }
          ]
        },
        summary: { errors: 0, warnings: 2, total: 2 }
      )

      # No mocking library is available (minitest 6 dropped minitest/mock and
      # it isn't a project dependency), so swap the class method by hand and
      # restore it no matter what.
      original_call = WorkflowHealthCheck.method(:call)
      WorkflowHealthCheck.define_singleton_method(:call) { |_workflow| synthetic }
      begin
        get workflow_health_path(@workflow)
      ensure
        WorkflowHealthCheck.define_singleton_method(:call, original_call)
      end

      assert_response :success
      assert_not_includes response.body, "All checks passing"
      [
        "Reachability from start",
        "Every step can reach a Resolve step",
        "All terminals are Resolve steps",
        "No circular sub-flows",
        "All required fields present"
      ].each do |check|
        assert_includes response.body, check
      end
    end
  end
end
