require "test_helper"

# The outline's tree roles (workflows/_step_outline): a tree owns only
# treeitems and groups, so the empty state is never inside it, and the
# Unconnected section is a group named by its heading whose trees sit one
# level down.
class StepOutlineTreeTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @editor = User.create!(email: "editor-tree-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Tree WF", user: @editor, graph_mode: true)
    sign_in @editor
  end

  test "an empty workflow renders its empty state with no tree around it" do
    get workflow_path(@workflow, edit: true)

    assert_select "#steps-list .builder__empty"
    assert_select "[role='tree']", count: 0
    assert_select "#steps-list[role]", count: 0
  end

  test "unconnected steps sit in a labelled group, one level down, their exits one deeper" do
    start = Steps::Action.create!(workflow: @workflow, position: 0, title: "Start here")
    done = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done")
    Transition.create!(step: start, target_step: done)
    lone = Steps::Question.create!(workflow: @workflow, position: 2, title: "Lone question",
                                   answer_type: "yes_no", variable_name: "lone")
    yes_step = Steps::Resolve.create!(workflow: @workflow, position: 3, title: "Lone yes")
    Transition.create!(step: lone, target_step: yes_step, condition: "lone == 'yes'", label: "Yes", position: 0)
    @workflow.update_columns(start_step_id: start.id)

    get workflow_path(@workflow, edit: true)

    assert_select "#steps-list > [role='tree'][aria-label='Steps']" do
      assert_select "> ##{dom_id(start, :node)}[aria-level='1']"
      assert_select "> [role='group'][aria-labelledby='steps-unconnected-heading']" do
        assert_select "> #steps-unconnected-heading.builder__outline-section:not([role])",
                      text: "Unconnected: nothing leads here yet"
        assert_select "> ##{dom_id(lone, :node)}[aria-level='2']"
        assert_select "##{dom_id(yes_step, :node)}[aria-level='3']"
      end
    end
  end
end
