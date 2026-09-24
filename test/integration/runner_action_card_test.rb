require "test_helper"

# An Action step's Instructions box, in the runner. It was drawn whatever the
# step held, so an Action with no instructions showed an "Instructions"
# heading, a check icon and a copy button over nothing (seen 2026-09-24).
class RunnerActionCardTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "runner-action-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "admin")
    @workflow = Workflow.create!(title: "Action card WF", user: @user, status: "draft")
    @action = Steps::Action.create!(workflow: @workflow, title: "Power cycle the modem", position: 0)
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    Transition.create!(step: @action, target_step: done)
    @workflow.update!(start_step: @action)
    sign_in @user
  end

  # Mutation check: drop the `if` around the box in runner/_action - red.
  test "an Action with no instructions shows no Instructions box" do
    open_run

    assert_select ".step-content-box--action", count: 0
    assert_select "button[title='Copy instructions to clipboard']", count: 0
    assert_select "input[type=submit][value=?], button[type=submit]", "Continue"
  end

  # What an editor leaves behind when its text is cleared.
  test "instructions cleared to an empty paragraph count as none" do
    @action.update!(instructions: "<p><br></p>")
    open_run

    assert_select ".step-content-box--action", count: 0
  end

  test "an Action with instructions shows them, with its copy button" do
    @action.update!(instructions: "<p>Hold the reset button for ten seconds.</p>")
    open_run

    assert_select ".step-content-box--action", text: /Hold the reset button for ten seconds/ do
      assert_select "button[title='Copy instructions to clipboard']"
    end
  end

  # Same check on the Message card: an emptied message said nothing at all.
  test "a Message cleared to an empty paragraph says it has no content" do
    message = Steps::Message.create!(workflow: @workflow, title: "Read this out", position: 2, content: "<p><br></p>")
    Transition.create!(step: message, target_step: @action)
    @workflow.update!(start_step: message)
    open_run

    assert_select ".step-content-box--message", text: /No message content provided/
  end

  private

  def open_run
    post workflow_execution_path(@workflow)
    get step_scenario_path(Scenario.order(:id).last)
    assert_response :success
  end
end
