require "test_helper"

class TagTest < ActiveSupport::TestCase
  fixtures :tags, :taggings, :workflows, :users

  test "valid tag with name" do
    tag = Tag.new(name: "Priority")
    assert tag.valid?
  end

  test "invalid without name" do
    tag = Tag.new(name: nil)
    assert_not tag.valid?
    assert_includes tag.errors[:name], "can't be blank"
  end

  test "invalid with blank name" do
    tag = Tag.new(name: "   ")
    assert_not tag.valid?
  end

  test "name must be unique case-insensitively" do
    Tag.create!(name: "UniqueTest")
    duplicate = Tag.new(name: "uniquetest")
    assert_not duplicate.valid?
  end

  test "name is stripped and normalized on save" do
    tag = Tag.create!(name: "  Billing  ")
    assert_equal "Billing", tag.name
  end

  test "destroying tag cascades to taggings" do
    tag = tags(:urgent)
    workflow = workflows(:one)
    Tagging.create!(tag: tag, workflow: workflow)
    assert_difference "Tagging.count", -1 do
      tag.destroy
    end
  end

  test "tagging enforces workflow-tag uniqueness" do
    tag = tags(:urgent)
    workflow = workflows(:one)
    Tagging.create!(tag: tag, workflow: workflow)
    duplicate = Tagging.new(tag: tag, workflow: workflow)
    assert_not duplicate.valid?
  end

  test "workflow has_many tags through taggings" do
    tag = tags(:urgent)
    workflow = workflows(:one)
    workflow.tags << tag
    assert_includes workflow.tags, tag
  end
end
