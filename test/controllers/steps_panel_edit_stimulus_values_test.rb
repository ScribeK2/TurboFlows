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
end
