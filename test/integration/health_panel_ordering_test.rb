require "test_helper"

# What the health panel gives a first-time editor who added five steps by hand
# and has not drawn the connections yet.
#
# The list was ordered by the order the steps happened to be created in, so the
# rows carrying a Fix button were scattered among rows that are true only
# because of a step somewhere else. A watched first-time editor read the count
# as that many separate things wrong, gave up, and shipped a two-step workflow.
#
# Nothing here hides or downgrades a finding. The count is the same; the order
# and one line of explanation are the change.
class HealthPanelOrderingTest < ActionDispatch::IntegrationTest
  # One string per rendered issue row. Split on the row container class, not on
  # "health-panel__issue" — that prefix also matches __issue-icon, __issue-step
  # and __issue-note, so a word-boundary match finds four fragments per row.
  PASSING_HEADING = '<h4 class="health-panel__section-title">Passing</h4>'.freeze

  ROW_MARKER = 'class="list-row list-row--compact health-panel__issue"'.freeze

  setup do
    @user = User.create!(
      email: "health-order-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Five Steps By Hand", user: @user, status: "draft")
    @steps = Array.new(5) do |i|
      Steps::Question.create!(workflow: @workflow, position: i, title: "Step #{i + 1}",
                              question: "Question #{i + 1}?", answer_type: "text",
                              variable_name: "answer_#{i + 1}")
    end
    @workflow.update!(start_step: @steps.first)
    sign_in @user
  end

  test "precondition: this is the shape that produces a wall of errors" do
    health = WorkflowHealthCheck.call(@workflow)

    assert_operator health.summary[:errors], :>, 3, "five unwired steps produce more errors than actions"
    fixable = health.issues.values.flatten.count { |i| i[:severity] == :error && i[:fixable] }
    assert_operator fixable, :<, health.summary[:errors],
                    "and only some of them are things the reader can act on here"
  end

  test "rows that carry a Fix come before rows that do not" do
    body = panel
    errors_section = body[body.index("Errors")..body.index("Passing").to_i]

    rows = issue_rows(errors_section)
    fixable_flags = rows.map { |row| row.include?("step-warnings#fixFromPanel") }

    assert_includes fixable_flags, true, "precondition: some rows are fixable"
    assert_includes fixable_flags, false, "precondition: some rows are not"
    assert_equal fixable_flags.sort_by { |f| f ? 0 : 1 }, fixable_flags,
                 "every fixable row must come before every unfixable one"
  end

  test "a finding caused by another step says what will clear it" do
    body = panel

    assert_match(/Clears once another step connects to this one/, body)
    assert_select_note_belongs_to_unfixable_row(body)
  end

  test "the counts are untouched" do
    health = WorkflowHealthCheck.call(@workflow)
    body = panel

    assert_match(/#{health.summary[:errors]} errors/, body,
                 "ordering must not change what the panel says is wrong")
  end

  # The inline popover on a step row renders the same findings in JavaScript,
  # from the JSON. Sorting only in the panel left that popover showing the
  # consequence above the row with the button.
  test "within one step the actionable finding comes first" do
    health = WorkflowHealthCheck.call(@workflow)
    step_two = health.issues[@steps.second.uuid]

    assert_equal 2, step_two.size, "precondition: step 2 has a cause and a consequence"
    assert step_two.first[:fixable], "the one with a Fix leads"
    assert_not step_two.second[:fixable]
    assert_equal :unreachable_step, step_two.second[:code]
  end

  # Every note has to be keyed to a code something actually emits, or it is
  # documentation that never renders.
  test "every consequence note names a code the check can report" do
    known = WorkflowHealthCheck::PUBLISH_BLOCKING_CODES + WorkflowHealthCheck::NON_BLOCKING_CODES

    WorkflowHealthCheck::CONSEQUENCE_NOTES.each_key do |code|
      assert_includes known, code, "#{code} has a note but is not a code this check reports"
    end
  end

  # A note on a row that also carries a Fix would be telling the reader to wait
  # for something they could do right now.
  test "a fixable finding never carries a note" do
    health = WorkflowHealthCheck.call(@workflow)

    health.issues.values.flatten.each do |issue|
      next unless issue[:note]

      assert_not issue[:fixable], "#{issue[:code]} is fixable here and should not say it clears on its own"
    end
  end

  # The Passing section had two authors: the all-passing branch rendered each
  # check as a .list-row--compact with a check icon and a __title, and the
  # anything-failing branch rendered a bare `<li><%= check %></li>`. So
  # builder.css's `.health-panel__checklist .list-row__title` rule matched
  # nothing exactly when a reader has failures to read past, and the passing
  # rows read as unpadded body text in a box.
  test "a passing check renders as a row even while something is failing" do
    body = panel
    index = body.index(PASSING_HEADING)
    assert index, "precondition: this workflow has failures AND passing checks"

    list = body[index..][%r{<ul class="health-panel__checklist">(.*?)</ul>}m, 1]
    rows = list.to_s.scan(/<li[^>]*>/)

    assert_predicate rows, :any?, "precondition: the Passing section lists something"
    rows.each do |row|
      assert_includes row, "list-row list-row--compact",
                      "a passing row must be a row, the way the all-passing branch renders one"
    end
    assert_includes list, "health-panel__check-icon"
    assert_includes list, "list-row__title"
  end

  private

  def panel
    get workflow_health_path(@workflow)
    assert_response :success
    response.body
  end

  def issue_rows(html)
    html.split(ROW_MARKER).drop(1)
  end

  def assert_select_note_belongs_to_unfixable_row(body)
    rows = issue_rows(body)
    noted = rows.select { |row| row.include?("health-panel__issue-note") }

    assert_predicate noted, :any?, "precondition: at least one row carries a note"
    noted.each do |row|
      assert_not row.include?("step-warnings#fixFromPanel"), "a row with a Fix must not also say it clears on its own"
    end
  end
end
