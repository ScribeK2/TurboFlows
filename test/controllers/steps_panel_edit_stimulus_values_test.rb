require "test_helper"

# Nothing in the suite renders the answer-type grid or the form field builder
# end to end, so a rename or typo in the values-API wiring
# (`form_field_builder_controller.js`'s `static values = { fieldTypes: Array }`
# and the `data-form-field-builder-field-types-value` attribute in
# app/views/steps/fields/_form.html.erb) could break the builder in a browser
# with nothing here to catch it.
#
# This test catches attribute-name and encoding drift on the Ruby/ERB side: a
# renamed data attribute, or a `to_json` that stops being entity-escaped
# correctly in a non-html_safe interpolation. It does NOT catch a wrong
# `static values` key on the JS side — only a Capybara system test that drives
# "+ Add Field" and asserts all seven `<option>`s render would close that gap.
class StepsPanelEditStimulusValuesTest < ActionDispatch::IntegrationTest
  include WorkflowsHelper

  setup do
    @editor = User.create!(
      email: "editor-panel-edit-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Panel Edit Stimulus Values WF", user: @editor, graph_mode: true)
    sign_in @editor
  end

  test "the form step panel carries the field types the JS controller reads" do
    step = Steps::Form.create!(workflow: @workflow, position: 0, title: "Collect details")

    get panel_edit_workflow_step_path(@workflow, step)

    assert_response :success
    assert_includes response.body,
                    %(data-form-field-builder-field-types-value="#{ERB::Util.html_escape(Steps::Form::VALID_FIELD_TYPES.to_json)}")
  end

  test "the question step panel renders a radio option for every declared answer type" do
    step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Which issue?")

    get panel_edit_workflow_step_path(@workflow, step)

    assert_response :success

    Steps::Question::VALID_ANSWER_TYPES.each do |type|
      assert_includes response.body, %(value="#{type}")
    end
  end

  # variable_autocomplete_controller.js lost its mount in March and was deleted
  # (Q75). The placeholder still promised the dropdown it opened.
  test "the question step panel doesn't promise a variable dropdown" do
    step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Caller name?")

    get panel_edit_workflow_step_path(@workflow, step)

    assert_response :success
    assert_select "input[placeholder=?]", "Question text. Use {{variable_name}} for earlier answers"
    assert_no_match "to see available variables", response.body
    assert_no_match "variable-autocomplete-target", response.body
  end

  # The panel autosaves through requestSubmit(), which runs constraint
  # validation; an empty required field made the browser refuse every save.
  test "the step panel form doesn't let the browser refuse an autosave" do
    step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Caller name?")

    get panel_edit_workflow_step_path(@workflow, step)

    assert_response :success
    assert_select "form[data-controller='inline-autosave'][novalidate]"
  end

  test "the transitions editor carries sentence targets and variables JSON, not a raw custom field" do
    earlier = Steps::Question.create!(
      workflow: @workflow, position: 0, title: "Already verified?",
      question: "Already?", answer_type: "yes_no", variable_name: "already_verified"
    )
    later = Steps::Question.create!(
      workflow: @workflow, position: 1, title: "Did it work?",
      question: "Work?", answer_type: "yes_no", variable_name: "verified"
    )
    Transition.create!(step: later, target_step: earlier, position: 0, condition: "already_verified == 'yes'")

    get panel_edit_workflow_step_path(@workflow, later)

    assert_response :success
    assert_select "[data-condition-preset-target='sentenceContainer']"
    assert_select "[data-condition-preset-target='sentenceVariable']"
    assert_select "[data-condition-preset-target='sentenceOperator']"
    assert_select "[data-condition-preset-target='sentenceValue']"
    assert_select "[data-condition-preset-target='keepAsWritten']"
    assert_select "[data-condition-preset-target='customInput']", count: 0
    assert_no_match "e.g., answer ==", response.body

    json = ERB::Util.html_escape(condition_sentence_variables(@workflow, later).to_json)
    assert_includes response.body, %(data-condition-preset-variables-value="#{json}")
  end

  test "the connection row markup lives in the ERB template, not in JavaScript" do
    source = Rails.root.join("app/javascript/controllers/step_transitions_controller.js").read
    assert_not_includes source, "data-condition-preset-target=",
                        "step_transitions_controller.js carries its own row markup again — rows are cloned from the ERB template"
    assert_not_includes source, "customInput"
    assert_not_includes source, "e.g., answer =="

    later = Steps::Question.create!(
      workflow: @workflow, position: 1, title: "Did it work?",
      question: "Work?", answer_type: "yes_no", variable_name: "verified"
    )

    get panel_edit_workflow_step_path(@workflow, later)

    assert_response :success
    %w[sentenceContainer sentenceVariable sentenceOperator sentenceValue keepAsWritten].each do |target|
      assert_select "template[data-step-transitions-target='rowTemplate'] [data-condition-preset-target='#{target}']",
                    { minimum: 1 }, "the row template is missing #{target}"
    end
  end
end
