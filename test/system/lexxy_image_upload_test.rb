require "application_system_test_case"
require "zlib"

# An image chosen in Lexxy uploads and is saved with the step. Lexxy previews a
# chosen image before it uploads, so an image on the page proves nothing: until
# 2026-09-13 the upload failed silently (see test/integration/importmap_pins_test.rb)
# while the editor kept showing it. This asserts the saved body and the blob.
class LexxyImageUploadTest < ApplicationSystemTestCase
  setup do
    @editor = User.create!(email: "wf-system-test-lexxy-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Lexxy upload #{SecureRandom.hex(3)}", user: @editor)
    @step = Steps::Action.create!(workflow: @workflow, title: "Check the router", position: 0)
    @png = tiny_png
  end

  teardown do
    ActiveStorage::Blob.where(filename: "lexxy-system-test.png").find_each(&:purge)
  end

  test "an image chosen with Lexxy's image button is uploaded and saved with the step" do
    sign_in_as @editor
    visit workflow_path(@workflow, edit: true)
    find("[data-action~='click->builder#openStep']", text: "Check the router").click
    assert_selector "lexxy-editor", wait: 10

    choose_image_in_lexxy(@png, "lexxy-system-test.png")

    assert_eventually(timeout: 15) { saved_blobs.any? }
    blob = saved_blobs.sole
    assert_equal "lexxy-system-test.png", blob.filename.to_s
    assert_equal @png.bytesize, blob.byte_size
    assert_equal @png, blob.download
  end

  private

  def saved_blobs
    ActionText::RichText.uncached do
      @step.reload.instructions&.body&.attachables.to_a.grep(ActiveStorage::Blob)
    end
  end

  # What choosing a file in the picker does: Lexxy's image button makes a file
  # input, and the browser fills it and fires change. A headless browser has no
  # picker to click, so the test fills the input itself.
  def choose_image_in_lexxy(bytes, filename)
    result = page.execute_script(<<~JS, [bytes].pack("m0"), filename)
      const [base64, name] = arguments;
      const data = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
      const button = [...document.querySelectorAll("lexxy-toolbar button")].find(b => (b.title || "").includes("Add images"));
      if (!button) return "no image button";
      button.click();
      const input = [...document.querySelectorAll("input[type=file]")].filter(i => i.accept === "image/*,video/*").pop();
      if (!input) return "no file input";
      const transfer = new DataTransfer();
      transfer.items.add(new File([data], name, { type: "image/png" }));
      input.files = transfer.files;
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return "chosen";
    JS
    assert_equal "chosen", result
  end

  # A 16x16 PNG, built here so the test needs no binary fixture.
  def tiny_png
    width = height = 16
    raw = (0...height).map { |y| "\x00".b + (0...width).map { |x| [x * 16, y * 16, 160].pack("C3") }.join }.join
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [width, height, 8, 2, 0, 0, 0].pack("N2C5")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(raw)) + chunk.call("IEND", "")
  end
end
