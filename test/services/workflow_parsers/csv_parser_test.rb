require "test_helper"

module WorkflowParsers
  class CsvParserTest < ActiveSupport::TestCase
    # ============================================================================
    # Test 1: Parses valid CSV with all step types
    # ============================================================================

    test "parses valid CSV with all supported step types" do
      content = <<~CSV
        workflow_title,id,type,title,question,instructions,content,resolution_type,resolution_notes,reason,priority
        My Workflow,step-1,question,Ask Name,What is your name?,,,,,,
        ,step-2,action,Do Work,,Perform the task,,,,,
        ,step-3,message,Notify,,,Hello there!,,,,
        ,step-4,escalate,Escalate To Team,,,,,,Needs help,high
        ,step-5,resolve,Done,,,,success,Completed successfully,,
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_not_nil result, "Parser should return result. Errors: #{parser.errors.inspect}"
      assert_equal "My Workflow", result[:title]
      assert_equal 5, result[:steps].length

      types = result[:steps].pluck("type")
      assert_includes types, "question"
      assert_includes types, "action"
      assert_includes types, "message"
      assert_includes types, "escalate"
      assert_includes types, "resolve"
    end

    # ============================================================================
    # Test 2: Requires type and title columns
    # ============================================================================

    test "returns error when type column is missing" do
      content = <<~CSV
        id,title,instructions
        step-1,Do Work,Do it
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_nil result
      assert parser.errors.any? { |e| e.include?("Missing required columns") },
             "Expected missing columns error, got: #{parser.errors.inspect}"
    end

    test "returns error when title column is missing" do
      content = <<~CSV
        id,type,instructions
        step-1,action,Do it
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_nil result
      assert parser.errors.any? { |e| e.include?("Missing required columns") },
             "Expected missing columns error, got: #{parser.errors.inspect}"
    end

    # ============================================================================
    # Test 3: Auto-converts deprecated step types with warnings
    # ============================================================================

    test "auto-converts deprecated decision type to question with warning" do
      content = <<~CSV
        id,type,title,question
        step-1,decision,Check Status,Is it valid?
        step-2,resolve,Done,
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_not_nil result
      converted = result[:steps].find { |s| s["title"] == "Check Status" }
      assert_not_nil converted
      assert_equal "question", converted["type"], "decision should be auto-converted to question"
      assert converted["_import_converted"], "Should be flagged as converted"
      assert_equal "decision", converted["_import_converted_from"]
      assert parser.warnings.any? { |w| w.downcase.include?("decision") },
             "Expected a warning about decision conversion"
    end

    test "auto-converts deprecated checkpoint type to message with warning" do
      content = <<~CSV
        id,type,title,content
        step-1,checkpoint,Review Point,Please review
        step-2,resolve,Done,
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_not_nil result
      converted = result[:steps].find { |s| s["title"] == "Review Point" }
      assert_not_nil converted
      assert_equal "message", converted["type"], "checkpoint should be auto-converted to message"
      assert converted["_import_converted"]
      assert_equal "checkpoint", converted["_import_converted_from"]
      assert parser.warnings.any? { |w| w.downcase.include?("checkpoint") },
             "Expected a warning about checkpoint conversion"
    end

    # ============================================================================
    # Test 4: Parses options column (JSON and comma-separated)
    # ============================================================================

    test "parses options column as comma-separated label:value pairs" do
      content = <<~CSV
        id,type,title,question,options
        step-1,question,Choose,Pick one,"Billing:billing, Technical:technical, Other:other"
        step-2,resolve,Done,
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_not_nil result
      question_step = result[:steps].find { |s| s["type"] == "question" }
      assert_predicate question_step["options"], :present?
      assert_equal 3, question_step["options"].length

      billing = question_step["options"].find { |o| o["value"] == "billing" || o[:value] == "billing" }
      assert_not_nil billing, "Should find billing option"
    end

    test "parses options column as JSON array" do
      content = <<~CSV
        id,type,title,question,options
        step-1,question,Choose,Pick one,"[{""label"":""Yes"",""value"":""yes""},{""label"":""No"",""value"":""no""}]"
        step-2,resolve,Done,
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_not_nil result
      question_step = result[:steps].find { |s| s["type"] == "question" }
      assert_predicate question_step["options"], :present?
      assert_equal 2, question_step["options"].length
    end

    # ============================================================================
    # Test 5: Parses transitions column for graph mode
    # ============================================================================

    test "parses transitions column for graph mode with semicolon-separated targets" do
      content = <<~CSV
        id,type,title,question,transitions
        step-1,question,Ask,Name?,step-2
        step-2,resolve,Done,
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_not_nil result, "Parser should return result. Errors: #{parser.errors.inspect}"
      first_step = result[:steps].find { |s| s["title"] == "Ask" }
      assert_predicate first_step["transitions"], :present?, "Step should have transitions"
      assert_equal "step-2", first_step["transitions"].first["target_uuid"]
    end

    test "parses transitions column with conditions in uuid:condition format" do
      content = <<~CSV
        id,type,title,transitions
        step-1,question,Check,"step-2:answer == 'yes';step-3:answer != 'yes'"
        step-2,action,Yes Path,step-4
        step-3,action,No Path,step-4
        step-4,resolve,Done,
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_not_nil result
      check_step = result[:steps].find { |s| s["title"] == "Check" }
      assert_predicate check_step["transitions"], :present?
      assert_equal 2, check_step["transitions"].length
      conditional = check_step["transitions"].find { |t| t["condition"].present? }
      assert_not_nil conditional, "Should have a conditional transition"
    end

    test "parses transitions column as JSON array" do
      content = <<~CSV
        id,type,title,transitions
        step-1,question,Q1,"[{""target_uuid"":""step-2"",""condition"":""x==1""}]"
        step-2,resolve,End,
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_not_nil result
      first_step = result[:steps].first
      assert_equal "step-2", first_step["transitions"].first["target_uuid"]
      assert_equal "x==1", first_step["transitions"].first["condition"]
    end

    # ============================================================================
    # Test 6: Returns error for malformed CSV
    # ============================================================================

    test "returns error for malformed CSV" do
      # An unclosed quote makes the CSV malformed
      malformed = "id,type,title\nstep-1,action,\"Unclosed quote\nstep-2,resolve,End"

      parser = WorkflowParsers::CsvParser.new(malformed)
      result = parser.parse

      assert_nil result
      assert_predicate parser.errors, :any?, "Should have at least one error"
    end

    # ============================================================================
    # Test 7: Returns error for CSV with no valid steps
    # ============================================================================

    test "returns error for CSV with header row but no data rows" do
      # When no data rows are present, csv.first is nil and title extraction crashes
      # with a StandardError which the parser rescues as "Error parsing CSV: ..."
      content = "type,title,instructions\n"

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_nil result
      assert_predicate parser.errors, :any?, "Should have at least one error for empty CSV"
    end

    test "returns error for CSV where all rows have blank type and title" do
      content = <<~CSV
        type,title,instructions
        ,,Some instructions
        ,,More instructions
      CSV

      parser = WorkflowParsers::CsvParser.new(content)
      result = parser.parse

      assert_nil result
      assert parser.errors.any? { |e| e.downcase.include?("no valid steps") },
             "Expected 'no valid steps' error, got: #{parser.errors.inspect}"
    end
  end
end
