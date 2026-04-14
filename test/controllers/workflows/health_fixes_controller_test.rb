# frozen_string_literal: true

require "test_helper"

module Workflows
  class HealthFixesControllerTest < ActionDispatch::IntegrationTest
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
      assert q.reload.transitions.any? { |t| t.target_step_id == r.id }
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
      assert a.reload.transitions.any? { |t| t.target_step_id == new_resolve.id }
    end

    test "add_resolve_after shifts subsequent step positions" do
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
      assert_equal 3, r.reload.position
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

      assert_response :unprocessable_entity
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
  end
end
