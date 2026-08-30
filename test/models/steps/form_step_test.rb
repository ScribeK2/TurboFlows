require "test_helper"

module Steps
  class FormStepTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "form@test.com", password: "password123!", role: "admin")
      @workflow = Workflow.create!(title: "Form Flow", user: @user)
    end

    test "valid form step with fields" do
      step = Steps::Form.new(
        workflow: @workflow, title: "Customer Info", uuid: SecureRandom.uuid, position: 0,
        options: [
          { "name" => "account_number", "label" => "Account Number", "field_type" => "text", "required" => true, "position" => 0 },
          { "name" => "email", "label" => "Email", "field_type" => "email", "required" => true, "position" => 1 }
        ]
      )
      assert_predicate step, :valid?
    end

    test "form step type is form" do
      step = Steps::Form.new(workflow: @workflow, title: "F", uuid: SecureRandom.uuid, position: 0)
      assert_equal "form", step.step_type
    end

    test "fields returns options as field definitions" do
      fields = [{ "name" => "phone", "label" => "Phone", "field_type" => "phone", "required" => false, "position" => 0 }]
      step = Steps::Form.create!(workflow: @workflow, title: "F", uuid: SecureRandom.uuid, position: 0, options: fields)
      assert_equal fields, step.fields
    end

    test "required_field_names returns names of required fields" do
      fields = [
        { "name" => "phone", "label" => "Phone", "field_type" => "phone", "required" => true, "position" => 0 },
        { "name" => "notes", "label" => "Notes", "field_type" => "textarea", "required" => false, "position" => 1 }
      ]
      step = Steps::Form.create!(workflow: @workflow, title: "F", uuid: SecureRandom.uuid, position: 0, options: fields)
      assert_equal ["phone"], step.required_field_names
    end

    # Keyed by field, not a flat list of sentences. A long form rendered the flat
    # version as one block above the fields, leaving the agent to match each
    # message back to an input by reading the label out of the sentence.
    test "validate_responses names the field each message belongs to" do
      fields = [
        { "name" => "phone", "label" => "Phone", "field_type" => "phone", "required" => true, "position" => 0 },
        { "name" => "account", "label" => "Account", "field_type" => "text", "required" => true, "position" => 1 }
      ]
      step = Steps::Form.create!(workflow: @workflow, title: "F", uuid: SecureRandom.uuid, position: 0, options: fields)

      errors = step.validate_responses({ "account" => "AC-1" })

      assert_equal ["phone"], errors.keys, "only the field that failed is named"
      assert_match(/Phone/, errors["phone"].first)
    end

    test "validate_responses uses the field name when a field has no label" do
      fields = [{ "name" => "phone", "field_type" => "phone", "required" => true, "position" => 0 }]
      step = Steps::Form.create!(workflow: @workflow, title: "F", uuid: SecureRandom.uuid, position: 0, options: fields)

      assert_match(/phone/, step.validate_responses({})["phone"].first)
    end

    test "validate_responses passes with all required fields" do
      fields = [{ "name" => "phone", "label" => "Phone", "field_type" => "phone", "required" => true, "position" => 0 }]
      step = Steps::Form.create!(workflow: @workflow, title: "F", uuid: SecureRandom.uuid, position: 0, options: fields)
      errors = step.validate_responses({ "phone" => "555-1234" })
      assert_empty errors
    end

    test "field_by_name returns matching field" do
      fields = [
        { "name" => "phone", "label" => "Phone", "field_type" => "phone", "required" => true, "position" => 0 },
        { "name" => "notes", "label" => "Notes", "field_type" => "textarea", "required" => false, "position" => 1 }
      ]
      step = Steps::Form.create!(workflow: @workflow, title: "F", uuid: SecureRandom.uuid, position: 0, options: fields)
      assert_equal "Phone", step.field_by_name("phone")["label"]
      assert_nil step.field_by_name("missing")
    end

    test "outcome_summary shows field counts" do
      fields = [
        { "name" => "phone", "label" => "Phone", "field_type" => "phone", "required" => true, "position" => 0 },
        { "name" => "notes", "label" => "Notes", "field_type" => "textarea", "required" => false, "position" => 1 }
      ]
      step = Steps::Form.create!(workflow: @workflow, title: "F", uuid: SecureRandom.uuid, position: 0, options: fields)
      assert_equal "2 fields (1 required)", step.outcome_summary
    end
  end
end
