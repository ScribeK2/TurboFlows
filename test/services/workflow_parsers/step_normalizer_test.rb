require "test_helper"

module WorkflowParsers
  class StepNormalizerTest < ActiveSupport::TestCase
    def normalizer
      @normalizer ||= WorkflowParsers::StepNormalizer.new
    end

    # =========================================================================
    # #normalize — top-level array processing
    # =========================================================================

    test "normalize returns empty array for nil input" do
      assert_equal [], normalizer.normalize(nil)
    end

    test "normalize returns empty array for non-array input" do
      assert_equal [], normalizer.normalize("bad")
      assert_equal [], normalizer.normalize(42)
    end

    test "normalize skips non-hash elements" do
      result = normalizer.normalize([ nil, "string", 42 ])
      assert_equal [], result
    end

    test "normalize assigns UUIDs to all steps" do
      steps = [ { "type" => "action", "title" => "A" }, { "type" => "resolve", "title" => "End" } ]
      result = normalizer.normalize(steps)
      result.each { |s| assert_match(/\A[0-9a-f-]{36}\z/, s["id"]) }
    end

    test "normalize does not overwrite existing step ids" do
      steps = [ { "id" => "existing-uuid", "type" => "action", "title" => "A" } ]
      result = normalizer.normalize(steps)
      assert_equal "existing-uuid", result.first["id"]
    end

    # =========================================================================
    # #normalize_single_step — defaults
    # =========================================================================

    test "normalize_single_step returns nil for non-hash input" do
      assert_nil normalizer.normalize_single_step("bad", 0)
      assert_nil normalizer.normalize_single_step(nil, 0)
    end

    test "normalize_single_step defaults type to action" do
      result = normalizer.normalize_single_step({ "title" => "My Step" }, 0)
      assert_equal "action", result["type"]
    end

    test "normalize_single_step uses Step N as default title" do
      result = normalizer.normalize_single_step({}, 2)
      assert_equal "Step 3", result["title"]
    end

    test "normalize_single_step defaults description to empty string" do
      result = normalizer.normalize_single_step({ "type" => "action" }, 0)
      assert_equal "", result["description"]
    end

    # =========================================================================
    # #normalize_single_step — type-specific field extraction
    # =========================================================================

    test "normalize_single_step extracts question fields" do
      step = {
        "type"          => "question",
        "title"         => "Ask Name",
        "question"      => "What is your name?",
        "answer_type"   => "text",
        "variable_name" => "customer_name",
        "options"       => [ { "label" => "Yes", "value" => "yes" } ]
      }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "question",         result["type"]
      assert_equal "What is your name?", result["question"]
      assert_equal "text",             result["answer_type"]
      assert_equal "customer_name",    result["variable_name"]
      assert_equal 1,                  result["options"].length
    end

    test "normalize_single_step extracts action fields" do
      step = { "type" => "action", "title" => "Do Work", "instructions" => "Perform the task", "action_type" => "manual" }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "action",         result["type"]
      assert_equal "Perform the task", result["instructions"]
      assert_equal "manual",         result["action_type"]
    end

    test "normalize_single_step extracts message fields" do
      step = { "type" => "message", "title" => "Notice", "content" => "Hello!" }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "message", result["type"]
      assert_equal "Hello!",  result["content"]
    end

    test "normalize_single_step extracts escalate fields" do
      step = {
        "type"        => "escalate",
        "title"       => "Escalate",
        "target_type" => "team",
        "priority"    => "high",
        "reason"      => "Needs attention"
      }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "escalate",       result["type"]
      assert_equal "team",           result["target_type"]
      assert_equal "high",           result["priority"]
      assert_equal "Needs attention", result["reason"]
    end

    test "normalize_single_step defaults escalate priority to normal" do
      result = normalizer.normalize_single_step({ "type" => "escalate" }, 0)
      assert_equal "normal", result["priority"]
    end

    test "normalize_single_step extracts resolve fields" do
      step = { "type" => "resolve", "title" => "Done", "resolution_type" => "success", "resolution_notes" => "All good" }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "resolve",  result["type"]
      assert_equal "success",  result["resolution_type"]
      assert_equal "All good", result["resolution_notes"]
    end

    test "normalize_single_step extracts sub_flow fields" do
      step = {
        "type"               => "sub_flow",
        "title"              => "Sub",
        "target_workflow_id" => 42,
        "variable_mapping"   => { "in" => "out" }
      }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "sub_flow",     result["type"]
      assert_equal 42,             result["target_workflow_id"]
      assert_equal({ "in" => "out" }, result["variable_mapping"])
    end

    # =========================================================================
    # Deprecated-type conversion
    # =========================================================================

    test "normalize_single_step converts decision to question and adds warning" do
      step   = { "type" => "decision", "title" => "Choose" }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "question",  result["type"]
      assert result["_import_converted"], "Should flag as converted"
      assert_equal "decision",  result["_import_converted_from"]
      assert normalizer.warnings.any? { |w| w.include?("decision") }
    end

    test "normalize_single_step converts simple_decision to question and adds warning" do
      step   = { "type" => "simple_decision", "title" => "Simple Choose" }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "question",       result["type"]
      assert_equal "simple_decision", result["_import_converted_from"]
    end

    test "normalize_single_step converts checkpoint to message and adds warning" do
      step   = { "type" => "checkpoint", "title" => "Review", "checkpoint_message" => "Please review" }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal "message",    result["type"]
      assert_equal "Please review", result["content"]
      assert result["_import_converted"]
      assert_equal "checkpoint", result["_import_converted_from"]
      assert normalizer.warnings.any? { |w| w.include?("checkpoint") }
    end

    # =========================================================================
    # Transition and jump preservation
    # =========================================================================

    test "normalize_single_step preserves transitions array" do
      transitions = [ { "target_uuid" => "uuid-2", "condition" => nil } ]
      step        = { "type" => "action", "transitions" => transitions }
      result      = normalizer.normalize_single_step(step, 0)

      assert_equal 1,       result["transitions"].length
      assert_equal "uuid-2", result["transitions"].first["target_uuid"]
    end

    test "normalize_single_step preserves jumps array" do
      jumps  = [ { "condition" => "x == 1", "next_step_id" => "uuid-3" } ]
      step   = { "type" => "action", "jumps" => jumps }
      result = normalizer.normalize_single_step(step, 0)

      assert_equal jumps, result["jumps"]
    end

    # =========================================================================
    # Completeness checks
    # =========================================================================

    test "incomplete? returns true for question missing question text" do
      assert normalizer.incomplete?({ "type" => "question", "question" => "" })
    end

    test "incomplete? returns false for complete question step" do
      assert_not normalizer.incomplete?({ "type" => "question", "question" => "What?" })
    end

    test "incomplete? returns true for action missing instructions" do
      assert normalizer.incomplete?({ "type" => "action", "instructions" => "" })
    end

    test "incomplete? returns true for resolve missing resolution_type" do
      assert normalizer.incomplete?({ "type" => "resolve", "resolution_type" => "" })
    end

    test "incomplete? returns false for step types with no required fields" do
      assert_not normalizer.incomplete?({ "type" => "message" })
      assert_not normalizer.incomplete?({ "type" => "escalate" })
      assert_not normalizer.incomplete?({ "type" => "sub_flow" })
    end

    test "errors_for returns descriptive message for incomplete question" do
      errors = normalizer.errors_for({ "type" => "question", "question" => "" })
      assert_equal 1, errors.length
      assert_includes errors.first, "Question"
    end

    test "errors_for returns empty array for complete step" do
      assert_equal [], normalizer.errors_for({ "type" => "question", "question" => "What?" })
    end

    # =========================================================================
    # #normalize_transitions
    # =========================================================================

    test "normalize_transitions returns empty array for nil" do
      assert_equal [], normalizer.normalize_transitions(nil)
    end

    test "normalize_transitions skips non-hash elements" do
      assert_equal [], normalizer.normalize_transitions([ "bad", nil, 42 ])
    end

    test "normalize_transitions normalizes target_uuid and condition" do
      transitions = [ { "target_uuid" => "abc-123", "condition" => "x == 1", "label" => "Yes" } ]
      result      = normalizer.normalize_transitions(transitions)

      assert_equal 1,         result.length
      assert_equal "abc-123", result.first["target_uuid"]
      assert_equal "x == 1",  result.first["condition"]
      assert_equal "Yes",     result.first["label"]
    end

    test "normalize_transitions works with symbol keys" do
      result = normalizer.normalize_transitions([ { target_uuid: "uuid-1", condition: nil } ])
      assert_equal "uuid-1", result.first["target_uuid"]
    end

    # =========================================================================
    # #normalize_options
    # =========================================================================

    test "normalize_options returns empty array for nil" do
      assert_equal [], normalizer.normalize_options(nil)
    end

    test "normalize_options converts string elements to label/value pairs" do
      result = normalizer.normalize_options([ "Yes", "No" ])
      assert_equal 2, result.length
      assert_equal({ "label" => "Yes", "value" => "Yes" }, result.first)
      assert_equal({ "label" => "No",  "value" => "No" },  result.last)
    end

    test "normalize_options normalises hash elements using label and value keys" do
      opts   = [ { "label" => "Billing", "value" => "billing" }, { label: "Tech", value: "tech" } ]
      result = normalizer.normalize_options(opts)

      assert_equal 2,        result.length
      assert_equal "Billing", result[0]["label"]
      assert_equal "billing", result[0]["value"]
      assert_equal "Tech",   result[1]["label"]
    end

    # =========================================================================
    # #normalize_branches
    # =========================================================================

    test "normalize_branches returns empty array for nil" do
      assert_equal [], normalizer.normalize_branches(nil)
    end

    test "normalize_branches normalizes condition and path keys" do
      branches = [ { "condition" => "x > 0", "path" => "Step 2" } ]
      result   = normalizer.normalize_branches(branches)

      assert_equal "x > 0",  result.first["condition"]
      assert_equal "Step 2", result.first["path"]
    end

    test "normalize_branches works with symbol keys" do
      branches = [ { condition: "yes", path: "End" } ]
      result   = normalizer.normalize_branches(branches)

      assert_equal "yes", result.first["condition"]
      assert_equal "End", result.first["path"]
    end

    # =========================================================================
    # #ensure_uuids
    # =========================================================================

    test "ensure_uuids assigns UUIDs to steps without one" do
      steps = [ { "type" => "action" }, { "id" => "keep-me", "type" => "resolve" } ]
      normalizer.ensure_uuids(steps)

      assert_match(/\A[0-9a-f-]{36}\z/, steps[0]["id"])
      assert_equal "keep-me", steps[1]["id"]
    end

    test "ensure_uuids is a no-op for nil input" do
      assert_nil normalizer.ensure_uuids(nil)
    end

    # =========================================================================
    # #resolve_step_references (Markdown path)
    # =========================================================================

    test "resolve_step_references returns unchanged steps when no transitions reference step numbers" do
      steps = [
        { "id" => "u1", "type" => "action",  "title" => "A",   "transitions" => [] },
        { "id" => "u2", "type" => "resolve", "title" => "End", "transitions" => [] }
      ]
      result = normalizer.resolve_step_references(steps)
      assert_equal "u2", result.last["id"]
    end

    test "resolve_step_references resolves Step N references in transition target_uuid" do
      steps = [
        { "id" => "u1", "type" => "action",  "title" => "Step 1: Greet",
          "transitions" => [ { "target_uuid" => "Step 2", "condition" => nil } ] },
        { "id" => "u2", "type" => "resolve", "title" => "Step 2: Done", "transitions" => [] }
      ]
      result = normalizer.resolve_step_references(steps)

      assert_equal "u2", result.first["transitions"].first["target_uuid"]
    end

    test "resolve_step_references returns empty array for empty input" do
      assert_equal [], normalizer.resolve_step_references([])
    end
  end
end
