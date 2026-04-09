require "test_helper"

class HealthzTest < ActionDispatch::IntegrationTest
  test "healthz returns 200 OK without authentication" do
    get "/healthz"
    assert_response :success
    assert_equal "OK", response.body
  end
end
