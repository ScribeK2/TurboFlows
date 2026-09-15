require "application_system_test_case"
require "zlib"

# A file chosen in the step panel is attached the moment it is chosen. Before
# 2026-09-15 the panel showed a preview row and nothing ever reached the server.
class BuilderMediaAttachmentsTest < ApplicationSystemTestCase
  setup do
    @editor = User.create!(email: "wf-system-test-media-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Media upload #{SecureRandom.hex(3)}", user: @editor)
    @step = Steps::Action.create!(workflow: @workflow, title: "Check the router", position: 0)
    @png = tiny_png
  end

  teardown do
    ActiveStorage::Blob.where(filename: "media-system-test.png").find_each(&:purge)
  end

  test "choosing a file attaches it and lists it, and Remove takes it away" do
    sign_in_as @editor
    visit workflow_path(@workflow, edit: true)
    find("[data-action~='click->builder#openStep']", text: "Check the router").click
    assert_selector "[data-controller~='media-attachments']", wait: 10

    choose_file(@png, "media-system-test.png")

    within ".media-list:not(.media-list--pending)" do
      assert_text "media-system-test.png", wait: 15
    end
    assert_eventually(timeout: 15) { @step.reload.media_attachments.one? }
    assert_equal @png, @step.media_attachments.first.download

    click_on "Remove"
    assert_no_text "media-system-test.png", wait: 10
    assert_eventually(timeout: 10) { @step.reload.media_attachments.none? }
  end

  test "a file of the wrong type is refused before it uploads" do
    sign_in_as @editor
    visit workflow_path(@workflow, edit: true)
    find("[data-action~='click->builder#openStep']", text: "Check the router").click
    assert_selector "[data-controller~='media-attachments']", wait: 10

    choose_file("hello", "notes.txt", type: "text/plain")

    within "#flash" do
      assert_text "must be an image, video, or PDF", wait: 5
    end
    assert_equal 0, @step.reload.media_attachments.count
  end

  private

  # A headless browser has no picker, so the test fills the input itself and
  # fires the change the browser would.
  def choose_file(bytes, filename, type: "image/png")
    result = page.execute_script(<<~JS, [bytes].pack("m0"), filename, type)
      const [base64, name, type] = arguments;
      const data = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
      const input = document.querySelector("[data-media-attachments-target='input']");
      if (!input) return "no file input";
      const transfer = new DataTransfer();
      transfer.items.add(new File([data], name, { type }));
      input.files = transfer.files;
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return "chosen";
    JS
    assert_equal "chosen", result
  end

  def tiny_png
    width = height = 16
    raw = (0...height).map { |y| "\x00".b + (0...width).map { |x| [x * 16, y * 16, 160].pack("C3") }.join }.join
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [width, height, 8, 2, 0, 0, 0].pack("N2C5")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(raw)) + chunk.call("IEND", "")
  end
end
