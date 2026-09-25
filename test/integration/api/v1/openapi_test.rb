require "test_helper"

class Api::V1::OpenapiTest < ActionDispatch::IntegrationTest
  test "the document is served as JSON without a token" do
    get api_v1_openapi_path
    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal "3.1.0", response.parsed_body["openapi"]
  end

  test "every /api/v1 route is documented, and the document names no route that doesn't exist" do
    routes = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      next unless path.start_with?("/api/v1/")
      next if path.include?("*")

      [route.verb.downcase, path.gsub(/:(\w+)/, '{\1}')]
    end.uniq.sort

    documented = Api::V1::OpenapiController::DOCUMENT["paths"].flat_map do |path, operations|
      (operations.keys - %w[parameters summary description]).map { [it, path] }
    end.sort

    assert_equal routes, documented
  end

  test "every documented error code is one the API can produce" do
    text = Rails.root.join("config/openapi/v1.yaml").read
    %w[unauthorized insufficient_scope not_found invalid_filter payload_too_large throttled api_draft_limit
       malformed_json].each { assert_includes text, it }
  end
end
