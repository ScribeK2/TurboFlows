require "test_helper"

class DashboardHelperTest < ActionView::TestCase
  def setup
    @user = User.create!(
      email: "tz-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      display_name: "Aaron Weiward",
      time_zone: "America/Los_Angeles"
    )
  end

  test "time_based_greeting morning" do
    travel_to Time.utc(2026, 4, 28, 15, 0) do # 8 AM PDT
      assert_equal "Good morning", time_based_greeting(@user)
    end
  end

  test "time_based_greeting afternoon" do
    travel_to Time.utc(2026, 4, 28, 21, 0) do # 2 PM PDT
      assert_equal "Good afternoon", time_based_greeting(@user)
    end
  end

  test "time_based_greeting evening" do
    travel_to Time.utc(2026, 4, 29, 2, 0) do # 7 PM PDT
      assert_equal "Good evening", time_based_greeting(@user)
    end
  end

  test "time_based_greeting working late wraps past midnight" do
    travel_to Time.utc(2026, 4, 29, 8, 0) do # 1 AM PDT
      assert_equal "Working late", time_based_greeting(@user)
    end
  end

  test "time_based_greeting respects per-user time zone" do
    tokyo = User.create!(
      email: "tokyo-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      time_zone: "Asia/Tokyo"
    )

    # 23:00 UTC == 08:00 JST next day (morning) and 16:00 PDT (afternoon) same day
    travel_to Time.utc(2026, 4, 28, 23, 0) do
      assert_equal "Good morning", time_based_greeting(tokyo)
      assert_equal "Good afternoon", time_based_greeting(@user)
    end
  end

  test "time_based_greeting falls back to app time zone when user TZ is blank" do
    @user.update_columns(time_zone: "")
    travel_to Time.utc(2026, 4, 28, 8, 0) do
      assert_equal "Good morning", time_based_greeting(@user) # UTC default
    end
  end

  test "time_based_greeting tolerates invalid TZ string" do
    @user.update_columns(time_zone: "Not/A/Real/Zone")
    travel_to Time.utc(2026, 4, 28, 8, 0) do
      assert_equal "Good morning", time_based_greeting(@user)
    end
  end

  test "greeting_name uses first word of display_name" do
    assert_equal "Aaron", greeting_name(@user)
  end

  test "greeting_name falls back to email local-part when display_name is blank" do
    @user.update!(display_name: "")
    assert_equal @user.email.split("@").first, greeting_name(@user)
  end

  test "greeting_name returns empty string for nil user" do
    assert_equal "", greeting_name(nil)
  end

  test "greeting_date renders day-of-week and month-day in user TZ" do
    travel_to Time.utc(2026, 4, 28, 15, 0) do # Tuesday in PDT
      assert_equal "Tuesday, April 28", greeting_date(@user)
    end
  end
end
