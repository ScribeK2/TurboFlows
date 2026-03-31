require "test_helper"

module Admin
  class AnalyticsStepTimingTest < ActionDispatch::IntegrationTest
    setup do
      @admin = User.create!(
        email: "steptiming-#{SecureRandom.hex(4)}@test.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "admin"
      )
      sign_in @admin
      @workflow = Workflow.create!(title: "Step Timing Flow", user: @admin)

      Scenario.create!(
        workflow: @workflow,
        user: @admin,
        purpose: "live",
        outcome: "completed",
        started_at: 1.day.ago,
        completed_at: 1.day.ago + 2.minutes,
        duration_seconds: 120,
        execution_path: [
          { "step_title" => "Q1", "step_type" => "question", "started_at" => 1.day.ago.iso8601, "ended_at" => (1.day.ago + 30.seconds).iso8601, "duration_seconds" => 30.0 },
          { "step_title" => "A1", "step_type" => "action", "started_at" => (1.day.ago + 30.seconds).iso8601, "ended_at" => (1.day.ago + 90.seconds).iso8601, "duration_seconds" => 60.0 },
          { "step_title" => "R1", "step_type" => "resolve", "started_at" => (1.day.ago + 90.seconds).iso8601, "ended_at" => (1.day.ago + 120.seconds).iso8601, "duration_seconds" => 30.0 }
        ]
      )
    end

    test "step performance tab renders" do
      get admin_analytics_path
      assert_response :success
      assert_select "[data-tab='step-performance']", minimum: 1
    end
  end
end
