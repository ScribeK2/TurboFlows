require "test_helper"
require "rake"

class MigrateStepsTaskTest < ActiveSupport::TestCase
  def setup
    Rails.application.load_tasks unless Rake::Task.task_defined?("steps:migrate")
    @user = User.create!(email: "migrate-test@example.com", password: "password123!", password_confirmation: "password123!")
  end

  test "migrates JSONB steps to ActiveRecord models" do
    workflow = Workflow.create!(
      title: "Migration Test",
      user: @user,
      graph_mode: true,
      steps: [
        { "id" => "uuid-1", "type" => "question", "title" => "Q1", "question" => "What?", "answer_type" => "text", "variable_name" => "answer",
          "transitions" => [{ "target_uuid" => "uuid-2", "condition" => "answer == yes", "label" => "Yes" }] },
        { "id" => "uuid-2", "type" => "action", "title" => "A1", "instructions" => "**Do it**", "can_resolve" => true,
          "transitions" => [{ "target_uuid" => "uuid-3" }] },
        { "id" => "uuid-3", "type" => "resolve", "title" => "R1", "resolution_type" => "success", "transitions" => [] }
      ],
      start_node_uuid: "uuid-1"
    )

    # Run the migration
    Rake::Task["steps:migrate"].invoke

    # Verify step records were created
    assert_equal 3, workflow.workflow_steps.count

    q_step = workflow.workflow_steps.find_by(uuid: "uuid-1")
    assert_instance_of Steps::Question, q_step
    assert_equal "What?", q_step.question
    assert_equal "answer", q_step.variable_name
    assert_equal 0, q_step.position

    a_step = workflow.workflow_steps.find_by(uuid: "uuid-2")
    assert_instance_of Steps::Action, a_step
    assert a_step.can_resolve
    assert_includes a_step.instructions.body.to_s, "Do it"

    r_step = workflow.workflow_steps.find_by(uuid: "uuid-3")
    assert_instance_of Steps::Resolve, r_step
    assert_equal "success", r_step.resolution_type

    # Verify transitions
    assert_equal 1, q_step.transitions.count
    assert_equal a_step, q_step.transitions.first.target_step
    assert_equal "answer == yes", q_step.transitions.first.condition

    assert_equal 1, a_step.transitions.count
    assert_equal r_step, a_step.transitions.first.target_step

    assert_equal 0, r_step.transitions.count

    # Verify start_step_id
    workflow.reload
    assert_equal q_step.id, workflow.start_step_id
  ensure
    Rake::Task["steps:migrate"].reenable
  end

  test "skips workflows that already have ActiveRecord steps" do
    workflow = Workflow.create!(
      title: "Already Migrated",
      user: @user,
      steps: [
        { "id" => "uuid-a", "type" => "question", "title" => "Q1", "question" => "What?", "transitions" => [] }
      ]
    )

    # Pre-create an ActiveRecord step
    Steps::Question.create!(workflow: workflow, uuid: "uuid-a", position: 0, title: "Q1", question: "What?")

    # Run migration - should skip this workflow
    Rake::Task["steps:migrate"].invoke

    # Should still have exactly 1 step (not duplicated)
    assert_equal 1, workflow.workflow_steps.count
  ensure
    Rake::Task["steps:migrate"].reenable
  end

  test "migrates message step with rich text content" do
    workflow = Workflow.create!(
      title: "Message Test",
      user: @user,
      steps: [
        { "id" => "uuid-m", "type" => "message", "title" => "M1", "content" => "Hello **world**", "transitions" => [] }
      ]
    )

    Rake::Task["steps:migrate"].invoke

    m_step = workflow.workflow_steps.find_by(uuid: "uuid-m")
    assert_instance_of Steps::Message, m_step
    assert_includes m_step.content.body.to_s, "world"
  ensure
    Rake::Task["steps:migrate"].reenable
  end
end
