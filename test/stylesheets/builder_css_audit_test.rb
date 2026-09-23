require "test_helper"

# Surface 3 named connection crumbs by title, in a flex-shrink:0 nowrap
# column that grew the builder past the page edge. The outline took the crumbs
# off the row (the meta holds only "Start" / "Terminal" now), so what is left
# to lock is that the meta stays one line and never refuses to shrink, and
# that the list column can shrink below its content width.
class BuilderCssAuditTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/stylesheets/builder.css").read.freeze

  test "builder step meta stays on one line" do
    body = rule_body(".builder__step-meta") { |candidate| candidate.include?("white-space") }

    assert_includes body, "white-space: nowrap"
    assert_not_includes body, "flex-shrink: 0"
  end

  test "builder list can shrink below its content width" do
    body = rule_body(".builder__list") { |candidate| candidate.include?("flex-direction") }

    assert_includes body, "min-width: 0"
  end

  private

  # Leaf rule bodies only. Nested @media / @layer blocks contain braces and
  # never match, which is what we want — declarations live in leaves. Comments
  # sitting between rules are stripped so a heading above `.builder__list`
  # does not become part of the selector.
  def rule_body(selector, &)
    rules = CSS.to_enum(:scan, /([^{}]+)\{([^{}]*)\}/)
               .map { [Regexp.last_match(1), Regexp.last_match(2)] }

    bodies = rules.filter_map do |sel, body|
      last = sel.gsub(%r{/\*.*?\*/}m, "").strip.lines.last&.strip
      body if last == selector
    end
    assert_predicate bodies, :any?, "no rule for #{selector} in builder.css"

    chosen = bodies.find(&)
    assert chosen, "no #{selector} rule matched the filter"
    chosen
  end
end
