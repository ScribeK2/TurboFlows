require "test_helper"

# inline-autosave derives a field name from the element that fired the event.
# A Lexxy editor fires `lexxy:change` on the FORM, not on the input, so the
# lookup has to walk from the editor to the input it writes into. If that walk
# ever fails, the field is silently never marked dirty and rich text stops
# saving — a worse bug than the clobbering this mechanism replaces.
#
# Map-driven so a newly added rich-text field cannot skip the check.
class RichTextDirtyCoverageTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(
      email: "richtext-cov-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Rich Text WF", user: @editor, graph_mode: true)
    sign_in @editor
  end

  StepFieldMap::RICH_TEXT.each do |type, fields|
    fields.each do |field|
      test "a #{type} step's #{field} editor submits under a name inline-autosave can read" do
        step = Step.class_for_type(type).create!(
          workflow: @workflow, position: 0, title: "Rich #{type}",
          **self.class.required_attributes_for(type)
        )

        get panel_edit_workflow_step_path(@workflow, step)
        assert_response :success

        assert_match(/name="step\[#{field}\]"/, response.body,
                     "the #{field} editor must submit under step[#{field}], or the dirty " \
                     "lookup cannot name it and #{type}##{field} silently stops autosaving")
      end
    end
  end

  def self.required_attributes_for(type)
    case type
    when "escalate" then { target_type: "team", priority: "medium" }
    when "resolve" then { resolution_type: "success" }
    else {}
    end
  end
end
