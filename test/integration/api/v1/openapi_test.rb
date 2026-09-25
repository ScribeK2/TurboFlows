require "test_helper"
require "json_schemer"

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

  # Item 3 of the Phase 3 review: the description used to say MCP is
  # "described at /api/docs" — circular, since that page renders only this
  # document and has nothing more to say about MCP than this file does.
  test "the MCP mention points to the profile page's setup, not the circular /api/docs" do
    text = Rails.root.join("config/openapi/v1.yaml").read
    assert_includes text, "/mcp"
    assert_includes text, "profile page"
    assert_not_includes text, "/api/docs"
  end

  test "every documented error code is one the API can produce" do
    text = Rails.root.join("config/openapi/v1.yaml").read
    %w[unauthorized insufficient_scope not_found invalid_filter payload_too_large throttled api_draft_limit
       malformed_json].each { assert_includes text, it }
  end

  test "the document is a valid OpenAPI 3.1 document, including its $refs" do
    oas = JSONSchemer.openapi(Api::V1::OpenapiController::DOCUMENT)

    errors = oas.validate.to_a
    assert_empty errors, errors.pluck("error").join("\n")

    # JSONSchemer's own validate only checks the document is well-formed
    # OpenAPI — it never dereferences a $ref, so a $ref pointing nowhere
    # passes it silently. Walk every $ref in the document and resolve each
    # one for real.
    refs = []
    walk = lambda do |node|
      case node
      when Hash
        refs << node["$ref"] if node["$ref"]
        node.each_value(&walk)
      when Array
        node.each(&walk)
      end
    end
    walk.call(Api::V1::OpenapiController::DOCUMENT)

    assert_not_empty refs
    unresolved = refs.uniq.select do |ref|
      oas.ref(ref)
      false
    rescue JSONSchemer::InvalidRefPointer, JSONSchemer::InvalidRefResolution
      true
    end
    assert_empty unresolved, "$ref(s) that don't resolve: #{unresolved.join(', ')}"
  end
end
