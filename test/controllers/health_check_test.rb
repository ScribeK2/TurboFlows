require "test_helper"

class HealthCheckTest < ActionDispatch::IntegrationTest
  test "GET /up returns 200" do
    get "/up"
    assert_response :success
    assert_equal "OK", response.body
  end
end
