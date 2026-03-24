require "test_helper"

module WorkflowParsers
  class MarkdownParserTest < ActiveSupport::TestCase
    # ============================================================================
    # Test 1: Parses title from H1 header
    # ============================================================================

    test "parses title from H1 header" do
      md = <<~MD
        # My Workflow

        ## Step 1: Ask Name
        **Type**: question
        **Question**: What is your name?
      MD

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      assert_not_nil result
      assert_equal "My Workflow", result[:title]
    end

    # ============================================================================
    # Test 2: Parses title from frontmatter
    # ============================================================================

    test "parses title from frontmatter" do
      md = <<~MD
        ---
        title: "Frontmatter Title"
        description: "A workflow via frontmatter"
        ---

        ## Step 1: Do Something
        Type: action
        Instructions: Do it
      MD

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      assert_not_nil result
      assert_equal "Frontmatter Title", result[:title]
    end

    # ============================================================================
    # Test 3: Extracts description after title
    # ============================================================================

    test "extracts description after H1 title" do
      md = <<~MD
        # Title With Description

        This is the workflow description text.

        ## Step 1: Start
        Type: action
        Instructions: Begin the process
      MD

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      assert_not_nil result
      assert_includes result[:description], "This is the workflow description text."
    end

    # ============================================================================
    # Test 4: Extracts steps with type, question, and options fields
    # ============================================================================

    test "extracts steps with type, question, and options fields" do
      md = <<~MD
        # Options Workflow

        ## Step 1: Choose Issue
        **Type**: question
        **Question**: What kind of issue do you have?
        **Answer Type**: multiple_choice
        **Variable**: issue_type
        **Options**: Billing:billing, Technical:technical, Other:other
      MD

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      assert_not_nil result
      step = result[:steps].first
      assert_equal "question", step["type"]
      assert_equal "What kind of issue do you have?", step["question"]
      assert_equal 3, step["options"].length

      billing = step["options"].find { |o| o["value"] == "billing" }
      assert_not_nil billing
      assert_equal "Billing", billing["label"]
    end

    # ============================================================================
    # Test 5: Converts deprecated decision → question and checkpoint → message
    # ============================================================================

    test "converts deprecated decision type to question" do
      md = <<~MD
        # Deprecated Decision Test

        ## Step 1: Check Status
        Type: decision
        Condition: answer == 'yes'

        ## Step 2: Continue
        Type: action
        Instructions: Keep going
      MD

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      assert_not_nil result
      converted = result[:steps].find { |s| s["title"]&.include?("Check Status") }
      assert_not_nil converted, "Should find the converted step"
      assert_equal "question", converted["type"], "decision should be converted to question"
      assert converted["_import_converted"], "Should be flagged as converted"
      assert_equal "decision", converted["_import_converted_from"]
    end

    test "converts deprecated checkpoint type to message" do
      md = <<~MD
        # Deprecated Checkpoint Test

        ## Step 1: Review Point
        Type: checkpoint
        Content: Please review before continuing

        ## Step 2: Continue
        Type: action
        Instructions: Keep going
      MD

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      assert_not_nil result
      converted = result[:steps].find { |s| s["title"]&.include?("Review Point") }
      assert_not_nil converted, "Should find the converted checkpoint step"
      assert_equal "message", converted["type"], "checkpoint should be converted to message"
      assert converted["_import_converted"], "Should be flagged as converted"
      assert_equal "checkpoint", converted["_import_converted_from"]
    end

    # ============================================================================
    # Test 6: Parses transitions in graph mode format
    # ============================================================================

    test "parses transitions in graph mode format" do
      md = <<~MD
        # Graph Mode Workflow

        ## Step 1: Question
        Type: question
        Question: Which path?
        Transitions: Step 2 (if answer == 'yes'), Step 3

        ## Step 2: Yes Path
        Type: action
        Instructions: Do yes thing
        Transitions: Step 3

        ## Step 3: End
        Type: resolve
        Resolution Type: success
      MD

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      assert_not_nil result
      first_step = result[:steps].find { |s| s["title"]&.include?("Question") }
      assert_not_nil first_step
      assert_predicate first_step["transitions"], :present?, "Step should have transitions"
      # The conditional transition should have been recorded
      conditional = first_step["transitions"].find { |t| t["condition"].present? }
      assert_not_nil conditional, "Should have a conditional transition"
      assert_equal "answer == 'yes'", conditional["condition"]
    end

    # ============================================================================
    # Test 7: Returns error for file with no steps
    # ============================================================================

    test "returns error for markdown with no steps" do
      md = "# Workflow Without Steps\n\nThis has no steps defined at all.\n"

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      assert_nil result
      assert parser.errors.any? { |e| e.downcase.include?("no steps") },
             "Expected a 'no steps' error, got: #{parser.errors.inspect}"
    end

    # ============================================================================
    # Test 8: Adds warning for missing title
    # ============================================================================

    test "adds warning when no title is found" do
      md = <<~MD
        ## Step 1: Do Something
        Type: action
        Instructions: Just do it
      MD

      parser = WorkflowParsers::MarkdownParser.new(md)
      result = parser.parse

      # When no title found, parser adds a warning and uses default title
      assert parser.warnings.any? { |w| w.downcase.include?("title") },
             "Expected a title warning, got: #{parser.warnings.inspect}"
      # Result should still be returned with a default title
      assert_not_nil result
      assert_equal "Imported Workflow", result[:title]
    end
  end
end
