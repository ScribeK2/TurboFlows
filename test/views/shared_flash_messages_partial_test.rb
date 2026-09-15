require "test_helper"

# The partial iterates every flash key so that a message of a type nobody
# anticipated still renders instead of vanishing. What it must not render is a
# flash that is not a message at all: Devise sets flash[:timedout] = true beside
# the timeout alert, and that flag rendered as a green toast reading "true".
class SharedFlashMessagesPartialTest < ActionView::TestCase
  test "an unexpected text flash renders as a message and a non-text flag does not" do
    flash[:warning] = "Heads up"
    flash[:timedout] = true

    render partial: "shared/flash_messages"

    assert_select "div.flash", 1
    assert_select "div.flash.flash--notice .flash__text", text: "Heads up"
    assert_select ".flash__text", text: "true", count: 0
  end

  test "a blank message renders nothing" do
    flash[:notice] = ""

    render partial: "shared/flash_messages"

    assert_select "div.flash", 0
  end
end
