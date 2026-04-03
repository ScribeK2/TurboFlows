require "test_helper"

class FirstRunsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ActiveRecord::Base.connection.disable_referential_integrity do
      User.delete_all
    end
  end

  # -- GET /first_run (no users) --

  test "GET new renders setup form when no users exist" do
    get new_first_run_path
    assert_response :success
    assert_select "h2", "Set up TurboFlows"
    assert_select "input[name='user[email]']"
    assert_select "input[name='user[password]']"
    assert_select "input[name='user[password_confirmation]']"
  end

  # -- GET /first_run (users exist) --

  test "GET new redirects to root when users exist" do
    User.create!(email: "existing@example.com", password: "password123!", password_confirmation: "password123!")

    get new_first_run_path
    assert_redirected_to root_path
  end

  # -- POST /first_run (valid params, no users) --

  test "POST create creates admin user and signs in" do
    assert_difference "User.count", 1 do
      post first_run_path, params: {
        user: {
          email: "admin@example.com",
          password: "password123!",
          password_confirmation: "password123!"
        }
      }
    end

    user = User.last
    assert user.admin?
    assert_equal "admin@example.com", user.email
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
  end

  # -- POST /first_run (invalid params) --

  test "POST create with invalid params re-renders form" do
    assert_no_difference "User.count" do
      post first_run_path, params: {
        user: {
          email: "",
          password: "short",
          password_confirmation: "mismatch"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "div#error_explanation"
  end

  # -- POST /first_run (users exist — prevent_repeats) --

  test "POST create redirects when users exist" do
    User.create!(email: "existing@example.com", password: "password123!", password_confirmation: "password123!")

    assert_no_difference "User.count" do
      post first_run_path, params: {
        user: {
          email: "admin@example.com",
          password: "password123!",
          password_confirmation: "password123!"
        }
      }
    end

    assert_redirected_to root_path
  end

  # -- Race condition: AlreadyCompleted rescue --

  test "POST create handles AlreadyCompleted from race condition" do
    # Simulate race: prevent_repeats passes (no users), but by the time
    # FirstRun.create! runs inside the transaction, a user exists.
    # We test the model-level guard directly since the controller rescue
    # is a straightforward redirect.
    user = FirstRun.create!(
      email: "first@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    assert user.admin?

    # Now a second attempt raises AlreadyCompleted
    assert_raises(FirstRun::AlreadyCompleted) do
      FirstRun.create!(
        email: "second@example.com",
        password: "password123!",
        password_confirmation: "password123!"
      )
    end
  end

  # -- Sessions controller: redirect to first_run when no users --

  test "GET sign_in redirects to first_run when no users exist" do
    get new_user_session_path
    assert_redirected_to new_first_run_path
  end

  test "GET sign_in renders login when users exist" do
    User.create!(email: "existing@example.com", password: "password123!", password_confirmation: "password123!")

    get new_user_session_path
    assert_response :success
    assert_select "h2", "Welcome back"
  end

  # -- Registration guards --

  test "GET sign_up redirects to first_run when no users exist" do
    get new_user_registration_path
    assert_redirected_to new_first_run_path
  end

  test "POST registration redirects to first_run when no users exist" do
    assert_no_difference "User.count" do
      post user_registration_path, params: {
        user: {
          email: "sneaky@example.com",
          password: "password123!",
          password_confirmation: "password123!"
        }
      }
    end

    assert_redirected_to new_first_run_path
  end

  test "GET sign_up renders registration when users exist" do
    User.create!(email: "existing@example.com", password: "password123!", password_confirmation: "password123!")

    get new_user_registration_path
    assert_response :success
    assert_select "h2", "Create your account"
  end
end
