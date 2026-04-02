require "test_helper"

class FeatureFlagsHelperTest < ActionView::TestCase
  include FeatureFlagsHelper

  test "graph_mode_default? delegates to FeatureFlags module" do
    original_value = ENV["GRAPH_MODE_DEFAULT"]
    ENV["GRAPH_MODE_DEFAULT"] = "true"
    begin
      assert graph_mode_default?
    ensure
      ENV["GRAPH_MODE_DEFAULT"] = original_value
    end
  end

  test "show_graph_mode_toggle? returns true when graph mode is not default" do
    original_value = ENV["GRAPH_MODE_DEFAULT"]
    ENV["GRAPH_MODE_DEFAULT"] = "false"
    begin
      assert show_graph_mode_toggle?
    ensure
      ENV["GRAPH_MODE_DEFAULT"] = original_value
    end
  end

  test "show_graph_mode_toggle? returns false when graph mode is default and no param" do
    original_value = ENV["GRAPH_MODE_DEFAULT"]
    ENV["GRAPH_MODE_DEFAULT"] = "true"
    begin
      @controller.request.env["QUERY_STRING"] = ""
      assert_not show_graph_mode_toggle?
    ensure
      ENV["GRAPH_MODE_DEFAULT"] = original_value
    end
  end

  test "show_graph_mode_toggle? returns true when graph mode is default but param present" do
    original_value = ENV["GRAPH_MODE_DEFAULT"]
    ENV["GRAPH_MODE_DEFAULT"] = "true"
    begin
      @controller.request.env["QUERY_STRING"] = "show_mode_toggle=1"
      @controller.params = { show_mode_toggle: "1" }
      assert show_graph_mode_toggle?
    ensure
      ENV["GRAPH_MODE_DEFAULT"] = original_value
    end
  end
end
