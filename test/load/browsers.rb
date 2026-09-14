# Real browsers running alongside the k6 load (grill Q11, Q28, Q35). They catch
# what raw HTTP can't: a Turbo Stream that renders nothing, a click that does
# nothing, an autosave dropped in the page, a JavaScript error.
#
#   bundle exec ruby test/load/browsers.rb
#
# Environment:
#   BASE_URL (https://localhost:8443)   DURATION_MINUTES (30)   CSR_BROWSERS (3)
#   SANDBOX_WORKFLOW_ID                 the editor browser needs it (seeds/editor_sandbox.rb)
#   IDLE_CHECK=1                        also sit on an open run IDLE_MINUTES (31), then answer:
#                                       passes only if the agent is plainly told to sign in again
#   OUT (tmp/load-results/browsers)     screenshots of every failure land here
#
# Accounts csr241 upward, so they never share a session with a k6 VU.
# Exits 1 if any browser reported a failure.

require "bundler/setup"
require "capybara"
require "fileutils"
require "json"
require "selenium-webdriver"

BASE = ENV.fetch("BASE_URL", "https://localhost:8443")
PASSWORD = ENV.fetch("PASSWORD", "LoadTest!2026")
DEADLINE = Time.now.utc + (ENV.fetch("DURATION_MINUTES", "30").to_f * 60)
CSR_BROWSERS = ENV.fetch("CSR_BROWSERS", "3").to_i
IDLE_MINUTES = ENV.fetch("IDLE_MINUTES", "31").to_f
SANDBOX = ENV.fetch("SANDBOX_WORKFLOW_ID", nil)
OUT = ENV.fetch("OUT", "tmp/load-results/browsers")
SLOW_SECONDS = 1.0 # grill Q25: an answer should settle in under a second
FileUtils.mkdir_p(OUT)

Capybara.register_driver :load_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  %w[--headless=new --ignore-certificate-errors --window-size=1280,900 --disable-gpu --no-sandbox].each do |arg|
    options.add_argument(arg)
  end
  options.binary = "/usr/bin/chromium" if File.exist?("/usr/bin/chromium")
  options.accept_insecure_certs = true
  options.add_option("goog:loggingPrefs", { browser: "ALL" })
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end
Capybara.run_server = false
Capybara.app_host = BASE
Capybara.default_max_wait_time = 15

class Browser
  attr_reader :name, :stats, :failures

  def initialize(name)
    @name = name
    @session = Capybara::Session.new(:load_chrome)
    @stats = Hash.new(0)
    @answer_times = []
    @failures = []
  end

  def summary
    sorted = @answer_times.sort
    p95 = sorted.empty? ? nil : sorted[(sorted.size * 0.95).ceil - 1].round(3)
    stats.merge("answer_p95_seconds" => p95, "failures" => failures.size)
  end

  def fail!(what)
    shot = File.join(OUT, "#{name}-#{Time.now.utc.strftime('%H%M%S')}.png")
    @session.save_screenshot(shot) rescue nil # rubocop:disable Style/RescueModifier
    @failures << "#{Time.now.utc.strftime('%H:%M:%S')} #{what} (url #{@session.current_url}, screenshot #{shot})"
    warn "[#{name}] FAIL #{what}"
  end

  # Raises if the sign-in doesn't take, so a browser that can't get in stops
  # rather than reporting every later step as a failure too.
  def sign_in(email)
    @session.visit("/users/sign_in")
    @session.fill_in("user[email]", with: email)
    @session.fill_in("user[password]", with: PASSWORD)
    @session.click_button("Sign in")
    raise "could not sign in as #{email}" unless @session.has_no_current_path?("/users/sign_in", wait: 15)
  end

  # Collects console errors since the last call. Chrome keeps them per page.
  def js_errors!
    logs = @session.driver.browser.logs.get(:browser)
    logs.select { |entry| entry.level == "SEVERE" }.each do |entry|
      stats["js_errors"] += 1
      fail!("JavaScript error: #{entry.message[0, 200]}")
    end
  rescue StandardError
    nil
  end

  def open_card_id
    @session.first("#runner-card-current [id^='runner-card-']", minimum: 0, wait: 0)&.[](:id)
  end

  # One call: start the first workflow on /play and answer until the run ends.
  def run_call
    @session.visit("/play")
    @session.first("form.player-row__run button", minimum: 1).click
    unless @session.has_css?("#runner-card-current", wait: 15)
      fail!("starting a run showed no step")
      return
    end

    40.times do
      card = open_card_id
      return finished_call if card.nil? && @session.has_link?("View results", wait: 2)

      sleep(rand(2.0..5.0))
      clicked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answer_open_card
      # One wait for either outcome: a new open card, or the run's results link.
      # Waiting for the card first timed the last answer of every run at the
      # full 15s, since finishing a run opens no card.
      settled = @session.has_css?(
        "#runner-card-current [id^='runner-card-']:not(##{card}), a[href$='/show']", wait: 15
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - clicked_at

      unless settled
        fail!("answer on #{card} changed nothing on the page within 15s")
        return
      end
      if @session.has_css?("#flash .flash--alert", wait: 0)
        fail!("run halted: #{@session.find('#flash .flash--alert').text[0, 160]}")
      end

      @answer_times << elapsed
      stats["answers"] += 1
      stats["slow_answers"] += 1 if elapsed > SLOW_SECONDS
      js_errors!
      return finished_call if @session.has_link?("View results", wait: 0)
    end
    fail!("run did not end within 40 answers")
  end

  def answer_open_card
    within_card = "#runner-card-current"
    if @session.has_css?("#{within_card} input[type=radio][value=yes]", wait: 0)
      # Auto-advance: choosing an option submits.
      @session.find("#{within_card} input[type=radio][value=#{rand < 0.7 ? 'yes' : 'no'}]", visible: :all).click
    else
      @session.find("#{within_card} [type=submit]:not([name=resolved_here])", match: :first).click
    end
  end

  def finished_call
    stats["runs"] += 1
    @session.click_link("View results")
    fail!("results page did not load") unless @session.has_no_css?("#runner-card-current", wait: 15)
  end

  # Autosave a step title, reload, and check the save stuck.
  def edit_step
    @session.visit("/workflows/#{SANDBOX}")
    rows = @session.all("[data-builder-url-param$='/panel_edit']", minimum: 1)
    rows.sample.click
    field = @session.find("input[name='step[title]']", wait: 15)
    title = "Browser edit #{Time.now.utc.strftime('%H%M%S')}-#{rand(1000)}"
    field.fill_in(with: title)
    sleep 4 # inline-autosave waits 2s after the last keystroke
    @session.visit("/workflows/#{SANDBOX}")
    if @session.has_text?(title, wait: 10)
      stats["autosaves_confirmed"] += 1
    else
      fail!("autosaved title #{title.inspect} was not there after a reload")
    end
    js_errors!
  end

  def idle_then_answer
    @session.visit("/play")
    @session.first("form.player-row__run button", minimum: 1).click
    return fail!("idle check: starting a run showed no step") unless @session.has_css?("#runner-card-current", wait: 15)

    warn "[#{name}] sitting on an open run for #{IDLE_MINUTES} minutes"
    sleep(IDLE_MINUTES * 60)
    card = open_card_id
    answer_open_card
    sleep 10

    signed_out_page = @session.has_current_path?(%r{/users/sign_in}, wait: 0) ||
                      @session.has_css?("form[action='/users/sign_in']", wait: 0) ||
                      @session.has_text?(/sign in again|session (has )?expired|signed out/i, wait: 0)
    moved_on = card && @session.has_css?("#runner-card-current [id^='runner-card-']:not(##{card})", wait: 0)

    if signed_out_page
      stats["idle_check"] = "passed: told to sign in again"
    elsif moved_on
      stats["idle_check"] = "passed: the session was still valid and the answer went through"
    else
      stats["idle_check"] = "failed"
      fail!("after #{IDLE_MINUTES} idle minutes the answer did nothing visible and no sign-in prompt appeared")
    end
  end

  def quit
    @session.driver.quit
  rescue StandardError
    nil
  end
end

def survive(browser)
  yield
rescue StandardError => e
  browser.fail!("#{e.class}: #{e.message[0, 200]}")
end

browsers = []
threads = []

CSR_BROWSERS.times do |i|
  browser = Browser.new("csr-browser-#{i + 1}")
  browsers << browser
  threads << Thread.new do
    survive(browser) do
      browser.sign_in(format("csr%03d@loadtest.local", 241 + i))
      survive(browser) { browser.run_call } while Time.now.utc < DEADLINE
    end
    browser.quit
  end
end

if SANDBOX
  editor = Browser.new("editor-browser")
  browsers << editor
  threads << Thread.new do
    survive(editor) do
      editor.sign_in("editor05@loadtest.local")
      while Time.now.utc < DEADLINE
        survive(editor) { editor.edit_step }
        sleep 20
      end
    end
    editor.quit
  end
end

if ENV["IDLE_CHECK"] == "1"
  idler = Browser.new("idle-browser")
  browsers << idler
  threads << Thread.new do
    survive(idler) do
      idler.sign_in("csr250@loadtest.local")
      idler.idle_then_answer
    end
    idler.quit
  end
end

threads.each(&:join)

report = browsers.to_h { |b| [b.name, b.summary] }
File.write(File.join(OUT, "summary.json"), JSON.pretty_generate(report))
puts JSON.pretty_generate(report)
failures = browsers.flat_map { |b| b.failures.map { |f| "#{b.name}: #{f}" } }
puts failures.empty? ? "BROWSERS PASSED" : "BROWSER FAILURES:\n  #{failures.join("\n  ")}"
exit(failures.empty? ? 0 : 1)
