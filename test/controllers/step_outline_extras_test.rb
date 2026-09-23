require "test_helper"

# A connection no door claims renders as an extra chip under the step's exits
# (workflows/_step_node). One whole comparison reads through
# format_condition_for_display; anything ConditionEvaluator.complete? rejects
# stays raw in mono, because that helper misreads a compound condition.
class StepOutlineExtrasTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @editor = User.create!(email: "editor-extras-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Extras WF", user: @editor, graph_mode: true)
    @step = Steps::Action.create!(workflow: @workflow, position: 0, title: "Check the account")
    @target = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done")
    sign_in @editor
  end

  test "a single comparison reads as words, the raw condition in its title" do
    extra_with("tier >= 5")

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(@step, :node)} .builder__outline-door--extra .builder__outline-chip[title='tier >= 5']",
                  text: 'tier is at least "5"'
    assert_select "##{dom_id(@step, :node)} .builder__outline-chip--expression", count: 0
  end

  # Unquoted on purpose: format_condition_for_display reads this one as
  # 'tier is greater than "1 && score < 3"'.
  test "a compound condition stays raw, set as an expression" do
    extra_with("tier > 1 && score < 3")

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(@step, :node)} .builder__outline-door--extra .builder__outline-chip--expression",
                  text: "tier > 1 && score < 3"
  end

  # A second blank-condition edge on a one-door step: the first claims Next,
  # so this one can never fire and is an extra.
  test "a blank condition reads as Anything else" do
    Transition.create!(step: @step, target_step: @target, position: 0)
    other = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Other")
    Transition.create!(step: @step, target_step: other, position: 1)

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(@step, :node)} .builder__outline-door--extra .builder__outline-chip[title='Anything else']",
                  text: "Anything else"
  end

  private

  # The Next door wired first, so the conditional edge is the one nothing claims.
  def extra_with(condition)
    Transition.create!(step: @step, target_step: @target, position: 1)
    other = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Other")
    Transition.create!(step: @step, target_step: other, condition: condition, position: 0)
  end
end
