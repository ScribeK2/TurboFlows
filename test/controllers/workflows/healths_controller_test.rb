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
      json = JSON.parse(response.body)
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
      json = JSON.parse(response.body)
      assert_not json["clean"]
      assert json["summary"]["total"] > 0
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
      json = JSON.parse(response.body)
      summary = json["summary"]
      assert_kind_of Integer, summary["total"]
      assert_kind_of Integer, summary["errors"]
      assert_kind_of Integer, summary["warnings"]
      assert_equal summary["errors"] + summary["warnings"], summary["total"]
    end
  end
end
