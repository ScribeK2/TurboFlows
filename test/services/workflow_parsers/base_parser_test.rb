require "test_helper"

module WorkflowParsers
  # Minimal concrete subclass used to exercise BaseParser logic directly.
  # Only implements #parse so it can call protected helpers under test.
  class TestableParser < BaseParser
    def parse
      to_workflow_data({ title: "Test", steps: [] })
    end

    # Expose protected methods for white-box testing of normalisation logic.
    public :normalize_steps,
           :normalize_single_step,
           :normalize_transitions,
           :normalize_options,
           :detect_graph_format,
           :ensure_step_uuids,
           :convert_to_graph_format,
           :resolve_path_to_uuid,
           :is_step_incomplete?,
           :step_errors
  end

  class BaseParserTest < ActiveSupport::TestCase
    # ============================================================================
    # Test 1: #initialize — sets up clean state
    # ============================================================================

    test "initialises with file_content and empty errors and warnings" do
      parser = TestableParser.new("content")

      assert_equal "content", parser.file_content
      assert_empty parser.errors
      assert_empty parser.warnings
      assert_predicate parser, :valid?
    end

    # ============================================================================
    # Test 2: #parse — raises NotImplementedError on bare BaseParser
    # ============================================================================

    test "parse raises NotImplementedError on base class" do
      parser = BaseParser.new("anything")

      assert_raises(NotImplementedError) { parser.parse }
    end

    # ============================================================================
    # Test 3: #valid? — reflects errors array
    # ============================================================================

    test "valid? returns false when errors are present" do
      parser = TestableParser.new("")
      # Force an error through the protected method via a parse that goes wrong
      # by calling to_workflow_data with nil steps (triggers graceful empty result)
      assert_predicate parser, :valid?

      # Directly add an error by parsing with the concrete subclass but
      # stubbing it to record an error first.
      bad_parser = Class.new(BaseParser) do
        def parse
          add_error("Something went wrong")
          nil
        end
      end.new("bad")

      bad_parser.parse
      assert_not_predicate bad_parser, :valid?
    end

    # ============================================================================
    # Test 4: normalize_steps — returns [] for non-array input
    # ============================================================================

    test "normalize_steps returns empty array for nil input" do
      parser = TestableParser.new("")
      assert_equal [], parser.normalize_steps(nil)
    end

    test "normalize_steps returns empty array for non-array input" do
      parser = TestableParser.new("")
      assert_equal [], parser.normalize_steps("not an array")
      assert_equal [], parser.normalize_steps(42)
    end

    test "normalize_steps skips non-hash elements" do
      parser = TestableParser.new("")
      result = parser.normalize_steps([ nil, "string", 42 ])
      assert_equal [], result
    end

    # ============================================================================
    # Test 5: normalize_single_step — defaults
    # ============================================================================

    test "normalize_single_step sets default type to action" do
      parser = TestableParser.new("")
      result = parser.normalize_single_step({ "title" => "My Step" }, 0)
      assert_equal "action", result["type"]
    end

    test "normalize_single_step uses Step N as default title" do
      parser = TestableParser.new("")
      result = parser.normalize_single_step({}, 2)
      assert_equal "Step 3", result["title"]
    end

    test "normalize_single_step returns nil for non-hash input" do
      parser = TestableParser.new("")
      assert_nil parser.normalize_single_step("bad", 0)
      assert_nil parser.normalize_single_step(nil, 0)
    end

    # ============================================================================
    # Test 6: normalize_single_step — type-specific field extraction
    # ============================================================================

    test "normalize_single_step extracts question fields" do
      parser = TestableParser.new("")
      step = {
        "type" => "question",
        "title" => "Ask Name",
        "question" => "What is your name?",
        "answer_type" => "text",
        "variable_name" => "customer_name",
        "options" => [ { "label" => "Yes", "value" => "yes" } ]
      }
      result = parser.normalize_single_step(step, 0)

      assert_equal "question", result["type"]
      assert_equal "What is your name?", result["question"]
      assert_equal "text", result["answer_type"]
      assert_equal "customer_name", result["variable_name"]
      assert_equal 1, result["options"].length
    end

    test "normalize_single_step extracts action fields" do
      parser = TestableParser.new("")
      step = {
        "type" => "action",
        "title" => "Do Work",
        "instructions" => "Perform the task",
        "action_type" => "manual"
      }
      result = parser.normalize_single_step(step, 0)

      assert_equal "action", result["type"]
      assert_equal "Perform the task", result["instructions"]
      assert_equal "manual", result["action_type"]
    end

    test "normalize_single_step extracts message fields" do
      parser = TestableParser.new("")
      step = { "type" => "message", "title" => "Notice", "content" => "Hello!" }
      result = parser.normalize_single_step(step, 0)

      assert_equal "message", result["type"]
      assert_equal "Hello!", result["content"]
    end

    test "normalize_single_step extracts escalate fields" do
      parser = TestableParser.new("")
      step = {
        "type" => "escalate",
        "title" => "Escalate",
        "target_type" => "team",
        "priority" => "high",
        "reason" => "Needs attention"
      }
      result = parser.normalize_single_step(step, 0)

      assert_equal "escalate", result["type"]
      assert_equal "team", result["target_type"]
      assert_equal "high", result["priority"]
      assert_equal "Needs attention", result["reason"]
    end

    test "normalize_single_step extracts resolve fields" do
      parser = TestableParser.new("")
      step = {
        "type" => "resolve",
        "title" => "Done",
        "resolution_type" => "success",
        "resolution_notes" => "All good"
      }
      result = parser.normalize_single_step(step, 0)

      assert_equal "resolve", result["type"]
      assert_equal "success", result["resolution_type"]
      assert_equal "All good", result["resolution_notes"]
    end

    test "normalize_single_step extracts sub_flow fields" do
      parser = TestableParser.new("")
      step = {
        "type" => "sub_flow",
        "title" => "Sub",
        "target_workflow_id" => 42,
        "variable_mapping" => { "in" => "out" }
      }
      result = parser.normalize_single_step(step, 0)

      assert_equal "sub_flow", result["type"]
      assert_equal 42, result["target_workflow_id"]
      assert_equal({ "in" => "out" }, result["variable_mapping"])
    end

    # ============================================================================
    # Test 7: deprecated type auto-conversion
    # ============================================================================

    test "normalize_single_step converts decision to question and adds warning" do
      parser = TestableParser.new("")
      step = { "type" => "decision", "title" => "Choose" }
      result = parser.normalize_single_step(step, 0)

      assert_equal "question", result["type"]
      assert result["_import_converted"], "Should flag as converted"
      assert_equal "decision", result["_import_converted_from"]
      assert parser.warnings.any? { |w| w.include?("decision") }
    end

    test "normalize_single_step converts checkpoint to message and adds warning" do
      parser = TestableParser.new("")
      step = { "type" => "checkpoint", "title" => "Review", "checkpoint_message" => "Please review" }
      result = parser.normalize_single_step(step, 0)

      assert_equal "message", result["type"]
      assert_equal "Please review", result["content"]
      assert result["_import_converted"]
      assert_equal "checkpoint", result["_import_converted_from"]
      assert parser.warnings.any? { |w| w.include?("checkpoint") }
    end

    # ============================================================================
    # Test 8: is_step_incomplete? and step_errors
    # ============================================================================

    test "is_step_incomplete? returns true for question missing question text" do
      parser = TestableParser.new("")
      step = { "type" => "question", "question" => "" }
      assert parser.is_step_incomplete?(step)
    end

    test "is_step_incomplete? returns false for complete question step" do
      parser = TestableParser.new("")
      step = { "type" => "question", "question" => "What?" }
      assert_not parser.is_step_incomplete?(step)
    end

    test "is_step_incomplete? returns true for action missing instructions" do
      parser = TestableParser.new("")
      step = { "type" => "action", "instructions" => "" }
      assert parser.is_step_incomplete?(step)
    end

    test "is_step_incomplete? returns true for resolve missing resolution_type" do
      parser = TestableParser.new("")
      step = { "type" => "resolve", "resolution_type" => "" }
      assert parser.is_step_incomplete?(step)
    end

    test "is_step_incomplete? returns false for step types with no required fields" do
      parser = TestableParser.new("")
      assert_not parser.is_step_incomplete?({ "type" => "message" })
      assert_not parser.is_step_incomplete?({ "type" => "escalate" })
      assert_not parser.is_step_incomplete?({ "type" => "sub_flow" })
    end

    test "step_errors returns descriptive error message" do
      parser = TestableParser.new("")
      errors = parser.step_errors({ "type" => "question", "question" => "" })
      assert_equal 1, errors.length
      assert_includes errors.first, "Question"
    end

    # ============================================================================
    # Test 9: normalize_transitions
    # ============================================================================

    test "normalize_transitions returns empty array for nil" do
      parser = TestableParser.new("")
      assert_equal [], parser.normalize_transitions(nil)
    end

    test "normalize_transitions skips non-hash elements" do
      parser = TestableParser.new("")
      result = parser.normalize_transitions([ "bad", nil, 42 ])
      assert_equal [], result
    end

    test "normalize_transitions normalizes target_uuid and condition" do
      parser = TestableParser.new("")
      transitions = [
        { "target_uuid" => "abc-123", "condition" => "x == 1", "label" => "Yes" }
      ]
      result = parser.normalize_transitions(transitions)

      assert_equal 1, result.length
      assert_equal "abc-123", result.first["target_uuid"]
      assert_equal "x == 1", result.first["condition"]
      assert_equal "Yes", result.first["label"]
    end

    test "normalize_transitions works with symbol keys" do
      parser = TestableParser.new("")
      transitions = [ { target_uuid: "uuid-1", condition: nil, label: nil } ]
      result = parser.normalize_transitions(transitions)

      assert_equal "uuid-1", result.first["target_uuid"]
    end

    # ============================================================================
    # Test 10: normalize_options
    # ============================================================================

    test "normalize_options returns empty array for nil" do
      parser = TestableParser.new("")
      assert_equal [], parser.normalize_options(nil)
    end

    test "normalize_options converts string elements to label/value pairs" do
      parser = TestableParser.new("")
      result = parser.normalize_options([ "Yes", "No" ])

      assert_equal 2, result.length
      assert_equal({ "label" => "Yes", "value" => "Yes" }, result.first)
      assert_equal({ "label" => "No", "value" => "No" }, result.last)
    end

    test "normalize_options normalises hash elements using label and value keys" do
      parser = TestableParser.new("")
      opts = [ { "label" => "Billing", "value" => "billing" }, { label: "Tech", value: "tech" } ]
      result = parser.normalize_options(opts)

      assert_equal 2, result.length
      assert_equal "Billing", result[0]["label"]
      assert_equal "billing", result[0]["value"]
      assert_equal "Tech", result[1]["label"]
    end

    # ============================================================================
    # Test 11: detect_graph_format
    # ============================================================================

    test "detect_graph_format returns false for empty array" do
      parser = TestableParser.new("")
      assert_not parser.detect_graph_format([])
    end

    test "detect_graph_format returns false when no step has transitions" do
      parser = TestableParser.new("")
      steps = [ { "type" => "action", "title" => "A" } ]
      assert_not parser.detect_graph_format(steps)
    end

    test "detect_graph_format returns true when at least one step has transitions" do
      parser = TestableParser.new("")
      steps = [
        { "type" => "action", "title" => "A", "transitions" => [ { "target_uuid" => "uuid-2" } ] },
        { "type" => "resolve", "title" => "End" }
      ]
      assert parser.detect_graph_format(steps)
    end

    # ============================================================================
    # Test 12: ensure_step_uuids
    # ============================================================================

    test "ensure_step_uuids assigns UUIDs to steps without one" do
      parser = TestableParser.new("")
      steps = [ { "type" => "action", "title" => "A" }, { "type" => "resolve", "title" => "End", "id" => "existing-uuid" } ]
      parser.ensure_step_uuids(steps)

      assert_predicate steps[0]["id"], :present?, "Should assign a UUID"
      assert_match(/\A[0-9a-f-]{36}\z/, steps[0]["id"])
      assert_equal "existing-uuid", steps[1]["id"], "Existing ID should be preserved"
    end

    # ============================================================================
    # Test 13: convert_to_graph_format — linear to graph
    # ============================================================================

    test "convert_to_graph_format adds sequential transitions between non-resolve steps" do
      parser = TestableParser.new("")
      steps = [
        { "id" => "uuid-1", "type" => "action",  "title" => "Step A", "transitions" => [] },
        { "id" => "uuid-2", "type" => "resolve",  "title" => "End",    "transitions" => [] }
      ]
      result = parser.convert_to_graph_format(steps)

      first = result.find { |s| s["id"] == "uuid-1" }
      assert_equal 1, first["transitions"].length
      assert_equal "uuid-2", first["transitions"].first["target_uuid"]
    end

    test "convert_to_graph_format gives resolve steps no transitions" do
      parser = TestableParser.new("")
      steps = [
        { "id" => "uuid-1", "type" => "action",  "title" => "A", "transitions" => [] },
        { "id" => "uuid-2", "type" => "resolve",  "title" => "End", "transitions" => [] }
      ]
      result = parser.convert_to_graph_format(steps)

      resolve = result.find { |s| s["id"] == "uuid-2" }
      assert_empty resolve["transitions"]
    end

    test "convert_to_graph_format returns empty array for empty input" do
      parser = TestableParser.new("")
      assert_equal [], parser.convert_to_graph_format([])
    end

    # ============================================================================
    # Test 14: resolve_path_to_uuid
    # ============================================================================

    test "resolve_path_to_uuid returns nil for blank path" do
      parser = TestableParser.new("")
      assert_nil parser.resolve_path_to_uuid(nil, {})
      assert_nil parser.resolve_path_to_uuid("", {})
    end

    test "resolve_path_to_uuid resolves direct title match" do
      parser = TestableParser.new("")
      map = { "Ask Name" => "uuid-1" }
      assert_equal "uuid-1", parser.resolve_path_to_uuid("Ask Name", map)
    end

    test "resolve_path_to_uuid resolves case-insensitive title match" do
      parser = TestableParser.new("")
      map = { "Ask Name" => "uuid-1" }
      assert_equal "uuid-1", parser.resolve_path_to_uuid("ask name", map)
    end

    test "resolve_path_to_uuid returns nil for unresolvable path" do
      parser = TestableParser.new("")
      assert_nil parser.resolve_path_to_uuid("Nonexistent Step", { "Other" => "uuid-1" })
    end

    # ============================================================================
    # Test 15: to_workflow_data — shape of returned hash
    # ============================================================================

    test "to_workflow_data returns hash with expected keys" do
      parser = TestableParser.new("")
      result = parser.parse

      assert_equal "Test", result[:title]
      assert result.key?(:description)
      assert result.key?(:steps)
      assert result.key?(:graph_mode)
      assert result.key?(:import_metadata)
      assert_equal true, result[:graph_mode]
    end

    test "to_workflow_data sets import_metadata with source_format and timestamps" do
      parser = TestableParser.new("")
      result = parser.parse

      meta = result[:import_metadata]
      assert_not_nil meta
      assert meta.key?(:source_format)
      assert meta.key?(:imported_at)
      assert meta.key?(:warnings)
      assert meta.key?(:errors)
    end

    test "to_workflow_data defaults title to Imported Workflow when missing" do
      # TestableParser#parse calls to_workflow_data({title: "Test", steps: []})
      # We call to_workflow_data directly on the instance with no title key
      parser = TestableParser.new("")
      result = parser.send(:to_workflow_data, { steps: [] })

      assert_equal "Imported Workflow", result[:title]
    end

    test "to_workflow_data adds warning when converting linear to graph format" do
      parser = TestableParser.new("")
      result = parser.send(:to_workflow_data, {
        title: "Linear",
        steps: [
          { "id" => "u1", "type" => "action",  "title" => "A" },
          { "id" => "u2", "type" => "resolve", "title" => "End" }
        ]
      })
      assert_not_nil result
      assert result[:import_metadata][:warnings].any? { |w| w.include?("Graph Mode") }
    end
  end
end
