require "test_helper"

module WorkflowParsers
  class YamlParserTest < ActiveSupport::TestCase
    # ============================================================================
    # Test 1: Parses a minimal valid YAML workflow
    # ============================================================================

    test "parses minimal valid YAML with title and steps" do
      yaml = <<~YAML
        title: My Workflow
        steps:
          - type: action
            title: Do Something
            instructions: Just do it
          - type: resolve
            title: Done
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result, "Parser should return result. Errors: #{parser.errors.inspect}"
      assert_equal "My Workflow", result[:title]
      assert_equal 2, result[:steps].length
    end

    # ============================================================================
    # Test 2: Supports wrapped format (workflow: ...)
    # ============================================================================

    test "parses wrapped YAML format with top-level 'workflow' key" do
      yaml = <<~YAML
        workflow:
          title: Wrapped Workflow
          description: Imported via wrap
          steps:
            - type: resolve
              title: End
              resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result
      assert_equal "Wrapped Workflow", result[:title]
      assert_equal "Imported via wrap", result[:description]
    end

    # ============================================================================
    # Test 3: Parses all supported step types
    # ============================================================================

    test "parses YAML with all supported step types" do
      yaml = <<~YAML
        title: All Types
        steps:
          - type: question
            title: Ask
            question: What?
            answer_type: text
          - type: action
            title: Act
            instructions: Do it
          - type: message
            title: Msg
            content: Hello
          - type: escalate
            title: Esc
            target_type: team
            priority: high
            reason: Need help
          - type: sub_flow
            title: Sub
            target_workflow_id: 99
          - type: resolve
            title: Done
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result
      types = result[:steps].pluck("type")
      assert_includes types, "question"
      assert_includes types, "action"
      assert_includes types, "message"
      assert_includes types, "escalate"
      assert_includes types, "sub_flow"
      assert_includes types, "resolve"
    end

    # ============================================================================
    # Test 4: Parses graph-mode fields (start_node_uuid, transitions)
    # ============================================================================

    test "parses graph mode fields and preserves explicit transitions" do
      step1_id = SecureRandom.uuid
      step2_id = SecureRandom.uuid

      yaml = <<~YAML
        title: Graph Workflow
        graph_mode: true
        start_node_uuid: "#{step1_id}"
        steps:
          - id: "#{step1_id}"
            type: question
            title: Which path?
            question: Yes or no?
            transitions:
              - target_uuid: "#{step2_id}"
                condition: "answer == 'yes'"
          - id: "#{step2_id}"
            type: resolve
            title: Done
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result
      assert result[:graph_mode]
      assert_equal step1_id, result[:start_node_uuid]

      first_step = result[:steps].find { |s| s["id"] == step1_id }
      assert_predicate first_step["transitions"], :present?
      assert_equal step2_id, first_step["transitions"].first["target_uuid"]
    end

    # ============================================================================
    # Test 5: Handles options in question steps
    # ============================================================================

    test "parses options in question steps" do
      yaml = <<~YAML
        title: With Options
        steps:
          - type: question
            title: Choose
            question: Which issue?
            options:
              - label: Billing
                value: billing
              - label: Technical
                value: technical
          - type: resolve
            title: End
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result
      q = result[:steps].find { |s| s["type"] == "question" }
      assert_equal 2, q["options"].length
      assert_equal "Billing", q["options"].first["label"]
      assert_equal "billing", q["options"].first["value"]
    end

    # ============================================================================
    # Test 6: Returns nil with error for malformed YAML
    # ============================================================================

    test "returns nil and adds error for malformed YAML" do
      bad_yaml = "title: My Workflow\nsteps:\n  - type: action\n    title: [unclosed bracket"

      parser = WorkflowParsers::YamlParser.new(bad_yaml)
      result = parser.parse

      assert_nil result
      assert parser.errors.any? { |e| e.downcase.include?("invalid yaml") || e.downcase.include?("yaml") },
             "Expected YAML syntax error, got: #{parser.errors.inspect}"
    end

    test "returns nil and adds error for empty string" do
      parser = WorkflowParsers::YamlParser.new("")
      result = parser.parse

      assert_nil result
      assert_predicate parser.errors, :any?
    end

    # ============================================================================
    # Test 7: Returns nil with error when title is missing
    # ============================================================================

    test "returns nil when title key is absent" do
      yaml = <<~YAML
        steps:
          - type: resolve
            title: End
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_nil result
      assert parser.errors.any? { |e| e.downcase.include?("title") },
             "Expected title error, got: #{parser.errors.inspect}"
    end

    test "returns nil when title is an empty string" do
      yaml = <<~YAML
        title: ""
        steps:
          - type: resolve
            title: End
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_nil result
      assert(parser.errors.any? { |e| e.downcase.include?("title") })
    end

    # ============================================================================
    # Test 8: Returns nil with error when structure is unrecognised
    # ============================================================================

    test "returns nil for YAML object with neither title nor steps nor workflow key" do
      yaml = "foo: bar\nbaz: 123\n"

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_nil result
      assert_predicate parser.errors, :any?
    end

    # ============================================================================
    # Test 9: Returns nil when steps is not an array
    # ============================================================================

    test "returns nil when steps is not an array" do
      yaml = <<~YAML
        title: Bad Steps
        steps: "not an array"
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_nil result
      assert parser.errors.any? { |e| e.downcase.include?("steps") },
             "Expected steps error, got: #{parser.errors.inspect}"
    end

    # ============================================================================
    # Test 10: Auto-converts deprecated step types
    # ============================================================================

    test "auto-converts deprecated decision type to question with warning" do
      yaml = <<~YAML
        title: Deprecated Test
        steps:
          - type: decision
            title: Choose
          - type: resolve
            title: Done
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result
      converted = result[:steps].find { |s| s["title"] == "Choose" }
      assert_equal "question", converted["type"]
      assert converted["_import_converted"]
      assert_equal "decision", converted["_import_converted_from"]
      assert(parser.warnings.any? { |w| w.downcase.include?("decision") })
    end

    test "auto-converts deprecated checkpoint type to message with warning" do
      yaml = <<~YAML
        title: Checkpoint Test
        steps:
          - type: checkpoint
            title: Review
            checkpoint_message: Please review before continuing
          - type: resolve
            title: Done
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result
      converted = result[:steps].find { |s| s["title"] == "Review" }
      assert_equal "message", converted["type"]
      assert converted["_import_converted"]
      assert_equal "checkpoint", converted["_import_converted_from"]
      assert(parser.warnings.any? { |w| w.downcase.include?("checkpoint") })
    end

    # ============================================================================
    # Test 11: Assigns UUIDs to steps without IDs
    # ============================================================================

    test "assigns UUIDs to steps that lack an id field" do
      yaml = <<~YAML
        title: UUID Test
        steps:
          - type: action
            title: Do It
            instructions: Go
          - type: resolve
            title: End
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result
      result[:steps].each do |step|
        assert_predicate step["id"], :present?, "Every step should have an id"
        assert_match(/\A[0-9a-f-]{36}\z/, step["id"])
      end
    end

    # ============================================================================
    # Test 12: valid? reflects parse outcome
    # ============================================================================

    test "valid? returns false after a parse error" do
      parser = WorkflowParsers::YamlParser.new("not: valid: yaml: [")
      parser.parse
      assert_not_predicate parser, :valid?
    end

    test "valid? returns true after successful parse" do
      yaml = "title: OK\nsteps:\n  - type: resolve\n    title: End\n    resolution_type: success\n"
      parser = WorkflowParsers::YamlParser.new(yaml)
      parser.parse
      assert_predicate parser, :valid?
    end

    # ============================================================================
    # Test 13: Linear format triggers graph conversion warning
    # ============================================================================

    test "adds warning when converting linear format to graph mode" do
      yaml = <<~YAML
        title: Linear
        steps:
          - type: action
            title: Step A
            instructions: Do it
          - type: resolve
            title: End
            resolution_type: success
      YAML

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result
      assert(result[:import_metadata][:warnings].any? { |w| w.include?("Graph Mode") })
    end

    # ============================================================================
    # Test 14: Normalises symbol keys from YAML symbol-key documents
    # ============================================================================

    test "handles YAML with symbol keys via permitted_classes" do
      # YAML.safe_load with permitted_classes: [Symbol] allows :key style
      yaml = ":title: Symbol Key Workflow\n:steps:\n  - :type: resolve\n    :title: End\n    :resolution_type: success\n"

      parser = WorkflowParsers::YamlParser.new(yaml)
      result = parser.parse

      assert_not_nil result, "Parser should handle symbol keys. Errors: #{parser.errors.inspect}"
      assert_equal "Symbol Key Workflow", result[:title]
    end
  end
end
