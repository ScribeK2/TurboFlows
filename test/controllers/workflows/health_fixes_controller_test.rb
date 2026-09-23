# frozen_string_literal: true

require "test_helper"
require "turbo/broadcastable/test_helper"

module Workflows
  class HealthFixesControllerTest < ActionDispatch::IntegrationTest
    include Turbo::Broadcastable::TestHelper

    def setup
      Bullet.enable = false
      @editor = User.create!(
        email: "fix-ed-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "editor"
      )
      @workflow = Workflow.create!(title: "Fix Flow", user: @editor, status: "draft")
      sign_in @editor
    end

    def teardown
      Bullet.enable = true
    end

    test "settle_connections moves the default connection last and adds or removes nothing" do
      q = Steps::Question.create!(workflow: @workflow, position: 0, title: "Ask", question: "What?",
                                  answer_type: "yes_no", variable_name: "ask")
      yes = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Yes side", resolution_type: "success")
      rest = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Everything else", resolution_type: "success")
      @workflow.update!(start_step: q)
      Transition.create!(step: q, target_step: rest, position: 0)
      Transition.create!(step: q, target_step: yes, condition: "ask == 'yes'", position: 1)

      assert_no_difference "Transition.count" do
        post workflow_health_fix_path(@workflow),
             params: { fix_type: "settle_connections", step_uuid: q.uuid },
             as: :turbo_stream
      end

      assert_response :success
      assert_equal ["ask == 'yes'", nil], q.transitions.reload.order(:position).map(&:condition)
      assert_equal yes, StepResolver.new(@workflow).resolve_next(q, { "ask" => "yes" })
      assert_select "turbo-stream[action='replace'][target='step-list']"
    end

    # A Fix writes a connection (or a step) like any grow or connect, so every
    # other tab on this workflow has to see it. It answered only the editor who
    # pressed it: another tab kept the stub, the old "ways in" and the old
    # numbers until something else broadcast (QA C-003, 2026-09-23).
    #
    # Mutation check: drop the broadcast_step_list call in
    # respond_with_updated_steps - red.
    test "a fix reaches every other tab: the list and the existing-step dialog are broadcast" do
      q = Steps::Question.create!(workflow: @workflow, position: 0, title: "Ask", question: "What?", answer_type: "text")
      Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Wrapped up", resolution_type: "success")
      @workflow.update!(start_step: q)

      broadcasts = capture_turbo_stream_broadcasts("workflow_#{@workflow.id}") do
        post workflow_health_fix_path(@workflow),
             params: { fix_type: "connect_next", step_uuid: q.uuid },
             as: :turbo_stream
      end

      assert_response :success
      list = broadcasts.find { |stream| stream["action"] == "update" && stream["target"] == "steps-list" }
      assert list, "a fix must broadcast the list"
      # Ask's Next door arrives wired (a step chip leading on to Wrapped up), not
      # as the "→ add step" stub the other tab is still showing.
      door = list.at_css(%([data-door-key="#{q.id}:Next"]))
      assert door, "the broadcast list shows Ask's Next door"
      assert_includes door["class"], "builder__outline-door--step", "the broadcast list carries the new connection"
      assert_not_includes list.to_html, "builder__door-stub", "no stub is left in the broadcast list"
      assert(broadcasts.any? { |stream| stream["target"] == "list-target-picker-options" },
             "the existing-step dialog's candidates ride along with the list")
    end

    test "connect_next creates transition to next step" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      r = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Done", resolution_type: "success"
      )
      @workflow.update!(start_step: q)

      assert_difference "Transition.count", 1 do
        post workflow_health_fix_path(@workflow),
             params: { fix_type: "connect_next", step_uuid: q.uuid },
             as: :turbo_stream
      end

      assert_response :success
      assert(q.reload.transitions.any? { |t| t.target_step_id == r.id })
    end

    test "add_resolve_after creates resolve step and transition" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      a = Steps::Action.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Do thing"
      )
      Transition.create!(step: q, target_step: a, position: 0)
      @workflow.update!(start_step: q)

      assert_difference "Steps::Resolve.count", 1 do
        post workflow_health_fix_path(@workflow),
             params: { fix_type: "add_resolve_after", step_uuid: a.uuid },
             as: :turbo_stream
      end

      assert_response :success
      new_resolve = Steps::Resolve.where(workflow: @workflow).order(:position).last
      assert_equal 2, new_resolve.position
      assert(a.reload.transitions.any? { |t| t.target_step_id == new_resolve.id })
    end

    # This test used to assert that applying the fix to a workflow which already
    # had a Resolve inserted a *second* one and shifted the first to position 3.
    # That was the behaviour, and it was the bug: it produced two Resolve steps
    # with the original stranded. The case it describes is exactly the one where
    # duplicating is wrong, so it now asserts the connection instead.
    test "add_resolve_after leaves positions alone when it can reuse an existing resolve" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      a = Steps::Action.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Do thing"
      )
      r = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 2,
        title: "End", resolution_type: "success"
      )
      Transition.create!(step: q, target_step: a, position: 0)
      @workflow.update!(start_step: q)

      post workflow_health_fix_path(@workflow),
           params: { fix_type: "add_resolve_after", step_uuid: a.uuid },
           as: :turbo_stream

      assert_response :success
      assert_equal 2, r.reload.position, "nothing was inserted, so nothing should shift"
      assert_equal [r.id], a.reload.transitions.map(&:target_step_id)
    end

    # The shifting itself still has to work, for the case where a Resolve really
    # does get inserted in the middle.
    test "add_resolve_after shifts subsequent positions when it does insert a step" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      a = Steps::Action.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Do thing"
      )
      tail = Steps::Message.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 2,
        title: "Trailing step", content: "Bye"
      )
      Transition.create!(step: q, target_step: a, position: 0)
      @workflow.update!(start_step: q)

      assert_difference "Steps::Resolve.where(workflow: @workflow).count", 1 do
        post workflow_health_fix_path(@workflow),
             params: { fix_type: "add_resolve_after", step_uuid: a.uuid },
             as: :turbo_stream
      end

      assert_response :success
      assert_equal 3, tail.reload.position, "the inserted Resolve must push later steps down"
    end

    test "connect_next with no next step returns alert" do
      a = Steps::Action.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Last"
      )
      @workflow.update!(start_step: a)

      post workflow_health_fix_path(@workflow),
           params: { fix_type: "connect_next", step_uuid: a.uuid },
           as: :turbo_stream

      assert_redirected_to workflow_path(@workflow, edit: true)
      assert_match(/no next step/i, flash[:alert])
    end

    test "invalid fix_type returns 422" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )

      post workflow_health_fix_path(@workflow),
           params: { fix_type: "invalid", step_uuid: q.uuid },
           as: :turbo_stream

      assert_response :unprocessable_content
    end

    test "nonexistent step returns 404" do
      post workflow_health_fix_path(@workflow),
           params: { fix_type: "connect_next", step_uuid: "nonexistent-uuid" },
           as: :turbo_stream

      assert_response :not_found
    end

    test "requires authentication" do
      sign_out @editor
      post workflow_health_fix_path(@workflow),
           params: { fix_type: "connect_next", step_uuid: "any" },
           as: :turbo_stream

      assert_response :unauthorized
    end

    test "viewer cannot apply fixes" do
      viewer = User.create!(
        email: "viewer-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "user"
      )
      sign_in viewer

      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )

      post workflow_health_fix_path(@workflow),
           params: { fix_type: "connect_next", step_uuid: q.uuid },
           as: :turbo_stream

      assert_redirected_to workflows_path
    end

    # -- Slice 3a/3b --------------------------------------------------------

    # `steps#create` streams `step-count-text`; this action streamed the list and
    # the health panel but not the count, so applying a fix that adds a step left
    # the toolbar reading "2 steps" above three rows.
    test "a fix that adds a step updates the step count in the toolbar" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      @workflow.update!(start_step: q)

      post workflow_health_fix_path(@workflow),
           params: { fix_type: "add_resolve_after", step_uuid: q.uuid },
           as: :turbo_stream

      assert_response :success
      assert_equal 2, @workflow.reload.steps.count
      assert_match(/step-count-text/, response.body,
                   "the fix changed the number of steps, so it has to refresh the count")
      assert_match(/2 steps/, response.body)
    end

    # add_resolve_after used to create a new Resolve unconditionally. Given a
    # workflow that already had one, it built a second and left the first
    # stranded — two Resolve steps, one dead, and the workflow now publishable.
    test "add_resolve_after connects to an existing reachable resolve instead of duplicating it" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      existing = Steps::Resolve.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
        title: "Already here", resolution_type: "success"
      )
      @workflow.update!(start_step: q)

      assert_no_difference "Steps::Resolve.where(workflow: @workflow).count" do
        post workflow_health_fix_path(@workflow),
             params: { fix_type: "add_resolve_after", step_uuid: q.uuid },
             as: :turbo_stream
      end

      assert_response :success
      assert_equal [existing.id], q.reload.transitions.map(&:target_step_id),
                   "the step must be wired to the Resolve that already existed"
    end

    test "add_resolve_after still creates one when the workflow has no resolve" do
      q = Steps::Question.create!(
        workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
        title: "Ask", question: "What?", answer_type: "text"
      )
      @workflow.update!(start_step: q)

      assert_difference "Steps::Resolve.where(workflow: @workflow).count", 1 do
        post workflow_health_fix_path(@workflow),
             params: { fix_type: "add_resolve_after", step_uuid: q.uuid },
             as: :turbo_stream
      end
    end
  end
end
