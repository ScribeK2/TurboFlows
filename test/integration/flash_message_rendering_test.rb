require "test_helper"

# Flash messages had drifted into three copies — one per layout — and the
# Player's had lost its `.flash__body`, which is where the fill, padding and
# radius live. A flash there rendered as unstyled ink text floating over the
# page, on the surface agents spend their day in.
#
# The guards here are about *structure*, because that is what a request test can
# see. Contrast is asserted separately in flash_contrast_test.rb, which reads the
# stylesheet, and placement was verified in a browser.
class FlashMessageRenderingTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(
      email: "flash-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "admin"
    )
  end

  test "every layout renders flashes through the shared partial" do
    layouts = Rails.root.glob("app/views/layouts/*.html.erb")
    offenders = layouts.reject do |path|
      body = File.read(path)
      # A layout either renders no flash at all, or renders the partial. What it
      # must never do is hand-roll the markup, which is how the Player's copy
      # lost its `.flash__body` without anything failing.
      body.exclude?("flash") || body.include?('render "shared/flash_messages"') ||
        body.match?(/flash\b.*only a comment/)
    end
    hand_rolled = offenders.select { |path| File.read(path).include?('class="flash flash--') }

    assert_empty hand_rolled.map { |p| Pathname(p).basename.to_s }, <<~MESSAGE
      These layouts build flash markup by hand instead of rendering
      `shared/flash_messages`. That is how the Player's copy drifted into a bare
      `<div class="flash flash--alert">` with no `.flash__body` — which carries
      the fill, padding and radius — so its flashes rendered as unstyled text.
    MESSAGE
  end

  test "a rendered flash carries the body element that styles it" do
    sign_in @admin
    # Any redirect that sets a flash will do; this one is a real user-facing path.
    patch update_role_admin_user_path(@admin), params: { role: "regular" }
    follow_redirect!

    # Scoped to #flash: the layout also keeps an empty alert in a <template> for
    # services/flash.js, and the HTML parser matches inside it.
    flash_el = css_select("#flash div.flash").first

    assert flash_el, "expected a flash to render"
    assert_not flash_el.css(".flash__text").text.strip.empty?, "expected the redirect's own message"
    assert_equal 1, flash_el.css(".flash__body").size,
                 "a .flash without a .flash__body has no fill, padding or radius"
    assert_equal 1, flash_el.css(".flash__text").size
    assert_equal 1, flash_el.css("button.flash__close").size,
                 "a message that auto-dismisses still needs a visible way to dismiss it"
  end

  # The partial's own header comment quoted an example containing a closing ERB
  # tag, which ended the comment early and dumped the rest of it into the page as
  # literal text — taking the layout's <main> with it. Every structural assertion
  # in this file stayed green, because the flash itself still rendered fine; only
  # a screenshot showed the page was empty. So: assert on the whole document.
  test "no layout leaks unrendered ERB into the page" do
    sign_in @admin

    [root_path, admin_users_path, workflows_path, play_path].each do |path|
      get path
      follow_redirect! while response.redirect?

      assert_no_match(/<%|%>/, response.body, <<~MESSAGE)
        #{path} rendered literal ERB delimiters.

        Usually an ERB comment containing `%>` — the comment ends at the first
        one, and everything after it becomes page content.
      MESSAGE
    end
  end

  # Devise's FailureApp sets flash[:timedout] = true next to the timeout alert,
  # and keeps both across the redirect to sign-in. The partial iterates every
  # flash key, so the flag rendered as a second toast reading "true", pinned to
  # the same corner as the real message and covering it. Devise's README says
  # the key is not meant for display.
  test "a timed-out session reaches sign-in with one message, not the timedout flag" do
    post user_session_path, params: { user: { email: @admin.email, password: "password123!" } }
    get workflows_path

    travel 31.minutes do
      get workflows_path
      follow_redirect! while response.redirect?
    end

    assert_equal new_user_session_path, request.path
    # Unscoped, because the devise layout keeps no <template> copy of a toast.
    # If it ever gains one, scope this the way the test above scopes to #flash.
    flashes = css_select("div.flash")

    assert_equal 1, flashes.size, "expected only the timeout message, got: #{flashes.map { |f| f.css('.flash__text').text.strip }.inspect}"
    assert_includes flashes.first["class"], "flash--alert"
    assert_equal I18n.t("devise.failure.timeout"), flashes.first.css(".flash__text").text.strip
  end
end
