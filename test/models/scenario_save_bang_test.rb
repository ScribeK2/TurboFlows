require "test_helper"

class ScenarioSaveBangTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "save-bang@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Save Bang WF", user: @user)
    @question = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    @resolve = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)
  end

  test "process_step raises on save failure instead of silently returning false" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "simulation",
      current_node_uuid: @question.uuid,
      execution_path: [], results: {}, inputs: {}
    )

    # Sabotage: set purpose to an invalid value to trigger validation failure on save
    scenario.purpose = "invalid_purpose"

    assert_raises(ActiveRecord::RecordInvalid) do
      scenario.process_step("Yes")
    end
  end
end
