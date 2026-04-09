require "test_helper"

module WorkflowParsers
  class TransitionBuilderTest < ActiveSupport::TestCase
    def builder
      @builder ||= WorkflowParsers::TransitionBuilder.new
    end

    # =========================================================================
    # #graph_format?
    # =========================================================================

    test "graph_format? returns false for empty array" do
      assert_not builder.graph_format?([])
    end

    test "graph_format? returns false for nil" do
      assert_not builder.graph_format?(nil)
    end

    test "graph_format? returns false when no step has transitions" do
      steps = [{ "type" => "action", "title" => "A" }]
      assert_not builder.graph_format?(steps)
    end

    test "graph_format? returns false when transitions arrays are empty" do
      steps = [{ "type" => "action", "transitions" => [] }]
      assert_not builder.graph_format?(steps)
    end

    test "graph_format? returns true when at least one step has non-empty transitions" do
      steps = [
        { "type" => "action",  "title" => "A", "transitions" => [{ "target_uuid" => "u2" }] },
        { "type" => "resolve", "title" => "End" }
      ]
      assert builder.graph_format?(steps)
    end

    # =========================================================================
    # #ensure_uuids
    # =========================================================================

    test "ensure_uuids assigns UUIDs to steps without one" do
      steps = [{ "type" => "action" }, { "id" => "existing", "type" => "resolve" }]
      builder.ensure_uuids(steps)

      assert_match(/\A[0-9a-f-]{36}\z/, steps[0]["id"])
      assert_equal "existing", steps[1]["id"]
    end

    test "ensure_uuids is a no-op for nil" do
      assert_nil builder.ensure_uuids(nil)
    end

    test "ensure_uuids skips non-hash elements" do
      steps = ["not a hash", nil, { "type" => "action" }]
      assert_nothing_raised { builder.ensure_uuids(steps) }
    end

    # =========================================================================
    # #convert_to_graph
    # =========================================================================

    test "convert_to_graph returns empty array for empty input" do
      assert_equal [], builder.convert_to_graph([])
    end

    test "convert_to_graph returns empty array for nil" do
      assert_equal [], builder.convert_to_graph(nil)
    end

    test "convert_to_graph adds sequential transition from action to next step" do
      steps = [
        { "id" => "u1", "type" => "action",  "title" => "A", "transitions" => [] },
        { "id" => "u2", "type" => "resolve", "title" => "End", "transitions" => [] }
      ]
      result = builder.convert_to_graph(steps)
      first  = result.find { |s| s["id"] == "u1" }

      assert_equal 1,    first["transitions"].length
      assert_equal "u2", first["transitions"].first["target_uuid"]
      assert_nil         first["transitions"].first["condition"]
    end

    test "convert_to_graph gives resolve steps no transitions" do
      steps = [
        { "id" => "u1", "type" => "action",  "title" => "A",   "transitions" => [] },
        { "id" => "u2", "type" => "resolve", "title" => "End", "transitions" => [] }
      ]
      result   = builder.convert_to_graph(steps)
      resolve  = result.find { |s| s["id"] == "u2" }

      assert_empty resolve["transitions"]
    end

    test "convert_to_graph does not add default transition when one already exists" do
      steps = [
        { "id" => "u1", "type" => "action", "title" => "A",
          "transitions" => [{ "target_uuid" => "u2", "condition" => nil }] },
        { "id" => "u2", "type" => "resolve", "title" => "End", "transitions" => [] }
      ]
      result = builder.convert_to_graph(steps)
      first  = result.find { |s| s["id"] == "u1" }

      assert_equal 1, first["transitions"].length
    end

    test "convert_to_graph converts jump conditions to conditional transitions" do
      steps = [
        { "id" => "u1", "type" => "question", "title" => "Ask",
          "transitions" => [],
          "jumps" => [{ "condition" => "answer == yes", "next_step_id" => "Resolve Step" }] },
        { "id" => "u2", "type" => "resolve", "title" => "Resolve Step", "transitions" => [] }
      ]
      result     = builder.convert_to_graph(steps)
      first      = result.find { |s| s["id"] == "u1" }
      conditions = first["transitions"].pluck("condition").compact

      assert_includes conditions, "answer == yes"
    end

    test "convert_to_graph skips jumps with blank next_step_id" do
      steps = [
        { "id" => "u1", "type" => "action", "title" => "A",
          "transitions" => [],
          "jumps" => [{ "condition" => "x", "next_step_id" => "" }] },
        { "id" => "u2", "type" => "resolve", "title" => "End", "transitions" => [] }
      ]
      result = builder.convert_to_graph(steps)
      first  = result.find { |s| s["id"] == "u1" }

      # Only the default sequential transition should be present
      assert_equal 1, first["transitions"].length
      assert_nil first["transitions"].first["condition"]
    end

    test "convert_to_graph handles multi-step linear sequences" do
      steps = [
        { "id" => "u1", "type" => "action",  "title" => "A", "transitions" => [] },
        { "id" => "u2", "type" => "action",  "title" => "B", "transitions" => [] },
        { "id" => "u3", "type" => "resolve", "title" => "C", "transitions" => [] }
      ]
      result = builder.convert_to_graph(steps)

      assert_equal "u2", result[0]["transitions"].first["target_uuid"]
      assert_equal "u3", result[1]["transitions"].first["target_uuid"]
      assert_empty result[2]["transitions"]
    end

    # =========================================================================
    # #normalize_transitions
    # =========================================================================

    test "normalize_transitions returns empty array for nil" do
      assert_equal [], builder.normalize_transitions(nil)
    end

    test "normalize_transitions skips non-hash elements" do
      assert_equal [], builder.normalize_transitions(["bad", nil, 42])
    end

    test "normalize_transitions normalises string and symbol keys" do
      transitions = [{ "target_uuid" => "u1", "condition" => "ok", "label" => "Yes" }]
      result      = builder.normalize_transitions(transitions)

      assert_equal "u1",  result.first["target_uuid"]
      assert_equal "ok",  result.first["condition"]
      assert_equal "Yes", result.first["label"]
    end

    test "normalize_transitions works with symbol keys" do
      result = builder.normalize_transitions([{ target_uuid: "u2", condition: nil }])
      assert_equal "u2", result.first["target_uuid"]
    end

    # =========================================================================
    # #resolve_path_to_uuid
    # =========================================================================

    test "resolve_path_to_uuid returns nil for blank path" do
      assert_nil builder.resolve_path_to_uuid(nil, {})
      assert_nil builder.resolve_path_to_uuid("",  {})
    end

    test "resolve_path_to_uuid resolves direct title match" do
      map = { "Ask Name" => "uuid-1" }
      assert_equal "uuid-1", builder.resolve_path_to_uuid("Ask Name", map)
    end

    test "resolve_path_to_uuid resolves case-insensitive title match" do
      map = { "Ask Name" => "uuid-1" }
      assert_equal "uuid-1", builder.resolve_path_to_uuid("ask name", map)
    end

    test "resolve_path_to_uuid returns already-known UUID unchanged" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      map  = { "Step A" => uuid }
      assert_equal uuid, builder.resolve_path_to_uuid(uuid, map)
    end

    test "resolve_path_to_uuid returns nil for unresolvable path" do
      assert_nil builder.resolve_path_to_uuid("Nonexistent", { "Other" => "uuid-1" })
    end

    # =========================================================================
    # #validate_graph_structure
    # =========================================================================

    test "validate_graph_structure is a no-op for empty steps" do
      assert_nothing_raised { builder.validate_graph_structure([], "some-uuid") }
      assert_empty builder.warnings
    end

    test "validate_graph_structure does not raise when GraphValidator is unavailable" do
      # GraphValidator may not be available in all test environments.
      # The method must rescue NameError gracefully.
      assert_nothing_raised do
        builder.validate_graph_structure(
          [{ "id" => "u1", "type" => "resolve", "title" => "End" }],
          "u1"
        )
      end
    end
  end
end
