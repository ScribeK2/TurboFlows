require "application_system_test_case"

# Server-side step validation, seen from the browser.
#
# A required checkbox is the one blocked path a browser can actually reach:
# scenarios/_form_step renders `required` on text, textarea and select fields
# but not on checkboxes, so native constraint validation lets the submit
# through and Steps::Form#validate_responses is what refuses it.
#
# The refusal has to be visible. It also has to be free: a blocked attempt
# changes nothing, so the run keeps whatever the user had already typed and
# records no visit to the step.
class RunnerValidationTest < ApplicationSystemTestCase
  test "a form step blocked on a required checkbox says so and keeps the typed values" do
    u = User.create!(email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
                     password: "password123!", password_confirmation: "password123!", role: "editor")
    wf = Workflow.create!(title: "Identity Check", user: u, status: "published")
    form = Steps::Form.create!(
      workflow: wf, title: "Verify the caller", position: 0,
      options: [
        { "name" => "customer_name", "label" => "Customer name",
          "field_type" => "text", "required" => true, "position" => 0 },
        { "name" => "identity_confirmed", "label" => "Confirmed identity",
          "field_type" => "checkbox", "required" => true, "position" => 1 }
      ]
    )
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    Transition.create!(step: form, target_step: done, position: 0)
    wf.update!(start_step: form)

    sign_in_as u
    visit new_workflow_execution_path(wf)
    click_on "Start Workflow"
    assert_current_step "Verify the caller"

    fill_in "answer[customer_name]", with: "Dana Whitfield"
    # Leave the required checkbox unchecked. The browser permits the submit
    # because no `required` attribute is rendered on it.
    click_on "Submit Form"

    assert_text "Confirmed identity is required"
    assert_current_step "Verify the caller"
    assert_field "answer[customer_name]", with: "Dana Whitfield"

    # A refused attempt is not a visited step: nothing lands in the trail.
    assert_empty Scenario.where(workflow: wf).last.execution_path
  end
end
