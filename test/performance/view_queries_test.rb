require "test_helper"

class ViewQueriesTest < ActiveSupport::TestCase
  test "sub_flow field partial does not contain direct Workflow.find_by" do
    partial_path = Rails.root.join("app/views/steps/fields/_sub_flow.html.erb")
    content = File.read(partial_path)

    refute_match(/Workflow\.find_by/, content,
      "steps/fields/_sub_flow.html.erb should not query the database directly. " \
      "Preload target workflows in the controller and pass via locals.")
  end
end
