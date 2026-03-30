require "test_helper"

class StepResponseTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "resp@test.com", password: "password123!", role: "admin")
    @workflow = Workflow.create!(title: "Resp Flow", user: @user)
    @step = Steps::Form.create!(workflow: @workflow, title: "Form", uuid: SecureRandom.uuid, position: 0,
      options: [{ "name" => "phone", "label" => "Phone", "field_type" => "text", "required" => true, "position" => 0 }])
    @scenario = Scenario.create!(workflow: @workflow, user: @user, purpose: "simulation")
  end

  test "valid step response" do
    response = StepResponse.new(scenario: @scenario, step: @step, responses: { "phone" => "555-1234" }, submitted_at: Time.current)
    assert response.valid?
  end

  test "invalid without scenario" do
    response = StepResponse.new(step: @step, responses: {}, submitted_at: Time.current)
    assert_not response.valid?
  end

  test "invalid without step" do
    response = StepResponse.new(scenario: @scenario, responses: {}, submitted_at: Time.current)
    assert_not response.valid?
  end

  test "invalid without submitted_at" do
    response = StepResponse.new(scenario: @scenario, step: @step, responses: {})
    assert_not response.valid?
  end

  test "responses stored as JSON" do
    response = StepResponse.create!(scenario: @scenario, step: @step, responses: { "phone" => "555-1234", "email" => "a@b.com" }, submitted_at: Time.current)
    response.reload
    assert_equal "555-1234", response.responses["phone"]
  end
end
