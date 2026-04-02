require "test_helper"

class StepTypeIconsTest < ActiveSupport::TestCase
  include StepTypeIcons

  test "returns icon for each known step type" do
    %w[question action sub_flow message escalate resolve form].each do |type|
      icon = step_type_icon(type)
      assert icon.present?, "Expected icon for step type '#{type}'"
      assert_not_equal StepTypeIcons::DEFAULT_ICON, icon, "Expected dedicated icon for '#{type}', got default"
    end
  end

  test "returns default icon for unknown step type" do
    assert_equal StepTypeIcons::DEFAULT_ICON, step_type_icon("unknown")
  end

  test "ICONS hash is frozen" do
    assert_predicate StepTypeIcons::ICONS, :frozen?
  end
end
