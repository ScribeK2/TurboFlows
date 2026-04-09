require "test_helper"

class FirstRunTest < ActiveSupport::TestCase
  setup do
    ActiveRecord::Base.connection.disable_referential_integrity do
      User.delete_all
    end
  end

  test "create! creates user with admin role" do
    user = FirstRun.create!(
      email: "admin@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )

    assert_predicate user, :persisted?
    assert_predicate user, :admin?
    assert_equal "admin@example.com", user.email
  end

  test "create! with invalid params raises RecordInvalid" do
    assert_raises(ActiveRecord::RecordInvalid) do
      FirstRun.create!(email: "", password: "", password_confirmation: "")
    end
  end

  test "create! when users exist raises AlreadyCompleted" do
    User.create!(email: "existing@example.com", password: "password123!", password_confirmation: "password123!")

    assert_raises(FirstRun::AlreadyCompleted) do
      FirstRun.create!(
        email: "admin@example.com",
        password: "password123!",
        password_confirmation: "password123!"
      )
    end
  end

  test "create! does not create user when AlreadyCompleted is raised" do
    User.create!(email: "existing@example.com", password: "password123!", password_confirmation: "password123!")

    assert_no_difference "User.count" do
      assert_raises(FirstRun::AlreadyCompleted) do
        FirstRun.create!(
          email: "admin@example.com",
          password: "password123!",
          password_confirmation: "password123!"
        )
      end
    end
  end
end
