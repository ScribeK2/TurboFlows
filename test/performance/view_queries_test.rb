require "test_helper"

class ViewQueriesTest < ActiveSupport::TestCase
  test "subflow_selector partial does not contain direct Workflow.find_by" do
    partial_path = Rails.root.join("app/views/workflows/_subflow_selector.html.erb")
    content = File.read(partial_path)

    refute_match(/Workflow\.find_by/, content,
      "_subflow_selector.html.erb should not query the database directly. " \
      "Preload target workflows in the controller and pass via locals.")
  end
end
