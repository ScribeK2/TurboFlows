require "application_system_test_case"

# The outline from the keyboard. Split from builder_outline_test.rb.
class BuilderOutlineKeyboardTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "outline-keys-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Modem light", user: @user, status: "draft")
    sign_in_as @user
  end

  teardown do
    User.where("email LIKE ?", "outline-keys-%").destroy_all
  end

  # Yes → Working, No → Power cycle → Did it come back? (Yes → Working, No →
  # Escalate): reading order Power light green?, Power cycle, Did it come
  # back?, Working (inside its Yes fold), Escalate to tier 2.
  def toy_graph
    @q1 = Steps::Question.create!(workflow: @workflow, title: "Power light green?", position: 0, answer_type: "yes_no", variable_name: "light")
    @working = Steps::Resolve.create!(workflow: @workflow, title: "Working", position: 1)
    @cycle = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 2)
    @q2 = Steps::Question.create!(workflow: @workflow, title: "Did it come back?", position: 3, answer_type: "yes_no", variable_name: "back")
    @escalate = Steps::Escalate.create!(workflow: @workflow, title: "Escalate to tier 2", position: 4)
    Transition.create!(step: @q1, target_step: @working, condition: "light == 'yes'", position: 0)
    Transition.create!(step: @q1, target_step: @cycle, condition: "light == 'no'", position: 1)
    Transition.create!(step: @cycle, target_step: @q2)
    Transition.create!(step: @q2, target_step: @working, condition: "back == 'yes'", position: 0)
    Transition.create!(step: @q2, target_step: @escalate, condition: "back == 'no'", position: 1)
    @workflow.update_columns(start_step_id: @q1.id)
  end

  # Keyboard access (QA A-004, 2026-09-23). A step's panel opened only on a
  # click - no row took focus, so a keyboard user could reach a step only
  # through a jump chip that pointed at it - while role="tree" promised
  # screen readers arrow keys that did nothing. Each step (its treeitem) is
  # now a Tab stop; Enter/Space open it; Up/Down/Home/End move between the
  # visible steps, skipping chips; Left folds the branch you're in, Right
  # unfolds the step's own folded branches. Chips, folds and Remove stay
  # ordinary Tab stops.
  #
  # Mutation check: stop mounting outline-keys in _builder.html.erb - red.
  test "a step is a Tab stop, and Enter or Space opens its panel" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    find(".builder__outline-toggle-all").send_keys(:tab)
    assert_equal @q1.uuid, focused_node_uuid, "Tab from Collapse all lands on the first step"
    send_keys_to_active(:enter)
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@q1.id}']", wait: 5

    execute_script("document.querySelector(\"[data-node-uuid='#{@cycle.uuid}']\").focus()")
    send_keys_to_active(:space)
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@cycle.id}']", wait: 5
  end

  test "arrow keys move between the visible steps in reading order" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5
    execute_script("document.querySelector(\"[data-node-uuid='#{@q1.uuid}']\").focus()")

    visited = [focused_node_uuid]
    4.times do
      send_keys_to_active(:down)
      visited << focused_node_uuid
    end
    assert_equal [@q1, @cycle, @q2, @working, @escalate].map(&:uuid), visited, "Down walks the reading order"

    send_keys_to_active(:up)
    assert_equal @working.uuid, focused_node_uuid
    send_keys_to_active(:home)
    assert_equal @q1.uuid, focused_node_uuid
    send_keys_to_active(:end)
    assert_equal @escalate.uuid, focused_node_uuid

    # A folded branch's steps are not visible, so Down skips them.
    find("details[data-fold-key='#{@q2.uuid}:Yes'] > summary").click
    execute_script("document.querySelector(\"[data-node-uuid='#{@q2.uuid}']\").focus()")
    send_keys_to_active(:down)
    assert_equal @escalate.uuid, focused_node_uuid, "Down skips a folded branch"
  end

  test "Left folds the branch you are in, and Right unfolds the step's own" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5
    fold = "details[data-fold-key='#{@q2.uuid}:Yes']"

    execute_script("document.querySelector(\"[data-node-uuid='#{@working.uuid}']\").focus()")
    send_keys_to_active(:left)
    assert_no_selector "#{fold}[open]"
    assert page.evaluate_script("document.activeElement === document.querySelector(\"#{fold} > summary\")"),
           "focus moves to the fold that closed"

    execute_script("document.querySelector(\"[data-node-uuid='#{@q2.uuid}']\").focus()")
    send_keys_to_active(:right)
    assert_selector "#{fold}[open]"

    # Left on a step that sits in no fold does nothing.
    send_keys_to_active(:left)
    assert_selector "#{fold}[open]"

    # A fold made from the keyboard is the author's, like a click: it survives
    # a re-render.
    execute_script("document.querySelector(\"[data-node-uuid='#{@working.uuid}']\").focus()")
    send_keys_to_active(:left)
    assert_no_selector "#{fold}[open]"
    open_step(@q1)
    fill_in "step[title]", with: "Renamed by keyboard test"
    assert_selector "#{STEP_ROW}[data-step-title='Renamed by keyboard test']", wait: 5
    assert_no_selector "#{fold}[open]"
  end

  test "a stub's type menu opened from the keyboard takes focus, and Escape gives it back" do
    q = Steps::Question.create!(workflow: @workflow, title: "Keys?", position: 0, answer_type: "yes_no", variable_name: "keys")
    @workflow.update_columns(start_step_id: q.id)
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 1, wait: 5

    stub = find(".builder__door-stub", text: "Yes → add step")
    stub.send_keys(:enter)
    assert page.evaluate_script("document.activeElement.classList.contains('builder__type-option')"),
           "focus moved into the type menu"
    send_keys_to_active(:escape)
    assert page.evaluate_script("document.activeElement === document.querySelector('.builder__door-stub')"),
           "Escape returns focus to the stub"
  end

  private

  def focused_node_uuid
    page.evaluate_script("document.activeElement.dataset.nodeUuid")
  end

  # Keys go to whatever has focus, as a keyboard's would.
  def send_keys_to_active(*keys)
    page.driver.browser.action.send_keys(*keys).perform
  end
end
