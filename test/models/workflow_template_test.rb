require "test_helper"

class WorkflowTemplateTest < ActiveSupport::TestCase
  test ".all returns a hash of all templates" do
    templates = WorkflowTemplate.all
    assert_instance_of Hash, templates
    assert_equal 5, templates.size
  end

  test ".keys returns all template keys" do
    keys = WorkflowTemplate.keys
    assert_includes keys, "guided_decision"
    assert_includes keys, "verification_checklist"
    assert_includes keys, "triage_and_escalate"
    assert_includes keys, "diagnosis_flow"
    assert_includes keys, "simple_handoff"
  end

  test ".find returns a template by key" do
    template = WorkflowTemplate.find("guided_decision")
    assert_equal "Guided Decision", template["name"]
    assert_equal "Questions → branches → outcomes", template["description"]
    assert_equal 250, template["hue"]
    assert template["steps"].is_a?(Array)
    assert template["steps"].size >= 4
    assert template["transitions"].is_a?(Array)
    assert template["transitions"].size >= 2
  end

  test ".find raises KeyError for unknown key" do
    assert_raises(KeyError) { WorkflowTemplate.find("nonexistent") }
  end

  test "every template has required fields" do
    WorkflowTemplate.all.each do |key, template|
      assert template["name"].present?, "#{key} missing name"
      assert template["description"].present?, "#{key} missing description"
      assert template["hue"].present?, "#{key} missing hue"
      assert template["steps"].is_a?(Array), "#{key} steps not an array"
      assert template["steps"].size >= 2, "#{key} needs at least 2 steps"
      assert template["transitions"].is_a?(Array), "#{key} transitions not an array"
    end
  end

  test "every template has at least one resolve step" do
    WorkflowTemplate.all.each do |key, template|
      resolve_steps = template["steps"].select { |s| s["type"] == "resolve" }
      assert resolve_steps.any?, "#{key} has no resolve step"
    end
  end

  test "every transition references valid step UUIDs" do
    WorkflowTemplate.all.each do |key, template|
      step_uuids = template["steps"].map { |s| s["uuid"] }
      template["transitions"].each do |t|
        assert_includes step_uuids, t["from"], "#{key}: transition from '#{t['from']}' references nonexistent step"
        assert_includes step_uuids, t["to"], "#{key}: transition to '#{t['to']}' references nonexistent step"
      end
    end
  end

  test "templates are frozen" do
    template = WorkflowTemplate.find("guided_decision")
    assert_raises(FrozenError) { template["name"] = "Modified" }
  end
end
