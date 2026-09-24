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
                      text: "Unconnected: not reached from the start"
        assert_select "> ##{dom_id(lone, :node)}[aria-level='2']"
        assert_select "##{dom_id(yes_step, :node)}[aria-level='3']"
      end
    end
  end

  # A fold, and the chip menu's focus return, find a door again by its key.
  # The key was "<step>:<label>", and nothing makes two answers' labels
  # unique, so two answers labelled "Same" folded and unfolded together
  # (QA B-002, 2026-09-23). A repeated label now gets its position.
  #
  # Mutation check: drop the "#n" suffix in _step_node's door_keys - red.
  test "two answers with the same label get separate fold and door keys" do
    q = Steps::Question.create!(workflow: @workflow, title: "Pick", position: 0, answer_type: "multiple_choice",
                                variable_name: "pick",
                                options: [{ "label" => "Same", "value" => "x" }, { "label" => "Same", "value" => "y" },
                                          { "label" => "Other", "value" => "z" }])
    went_x = Steps::Resolve.create!(workflow: @workflow, title: "Went X", position: 1)
    went_y = Steps::Resolve.create!(workflow: @workflow, title: "Went Y", position: 2)
    Transition.create!(step: q, target_step: went_x, condition: "pick == 'x'", position: 0)
    Transition.create!(step: q, target_step: went_y, condition: "pick == 'y'", position: 1)
    @workflow.update_columns(start_step_id: q.id)

    get workflow_path(@workflow, edit: true)

    fold_keys = css_select("details[data-fold-key]").pluck("data-fold-key")
    assert_equal ["#{q.uuid}:Same", "#{q.uuid}:Same#2"], fold_keys
    door_keys = css_select("[data-door-key^='#{q.id}:']").pluck("data-door-key")
    assert_equal door_keys.uniq, door_keys, "every door of a step has its own key"
    assert_includes door_keys, "#{q.id}:Other", "a unique label keeps its plain key"
  end
end
