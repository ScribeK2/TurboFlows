require "test_helper"

class ScenariosCssAuditTest < ActiveSupport::TestCase
  test "scenarios.css has no hardcoded hex colors outside data-URI exceptions" do
    css = File.read(Rails.root.join("app/assets/stylesheets/scenarios.css"))

    # Split into lines for per-line checking
    css.lines.each_with_index do |line, idx|
      line_num = idx + 1
      next if line.include?("data:image/svg+xml") # data-URI exception

      # Match #hex patterns (3, 4, 6, or 8 hex digits)
      hex_matches = line.scan(/#[0-9a-fA-F]{3,8}\b/)
      assert hex_matches.empty?,
        "scenarios.css:#{line_num} contains hardcoded hex color(s): #{hex_matches.join(', ')}. " \
        "Use OKLCH tokens or var() instead."
    end
  end

  test "scenarios.css has no rgba() values outside data-URI exceptions" do
    css = File.read(Rails.root.join("app/assets/stylesheets/scenarios.css"))

    css.lines.each_with_index do |line, idx|
      line_num = idx + 1
      next if line.include?("data:image/svg+xml")

      assert_not line.match?(/rgba\s*\(/),
        "scenarios.css:#{line_num} contains rgba(). Use oklch() instead."
    end
  end
end
