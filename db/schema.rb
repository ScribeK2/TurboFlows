# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_02_22_112120) do
  create_table "action_text_rich_texts", force: :cascade do |t|
    t.string "name", null: false
    t.text "body"
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "folders", force: :cascade do |t|
    t.string "name", null: false
    t.integer "group_id", null: false
    t.integer "parent_id"
    t.integer "position", default: 0
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id", "name"], name: "index_folders_on_group_id_and_name", unique: true
    t.index ["group_id", "position"], name: "index_folders_on_group_id_and_position"
    t.index ["group_id"], name: "index_folders_on_group_id"
    t.index ["parent_id"], name: "index_folders_on_parent_id"
  end

  create_table "group_workflows", force: :cascade do |t|
    t.integer "group_id", null: false
    t.integer "workflow_id", null: false
    t.boolean "is_primary", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "folder_id"
    t.index ["folder_id"], name: "index_group_workflows_on_folder_id"
    t.index ["group_id", "workflow_id"], name: "index_group_workflows_on_group_and_workflow", unique: true
    t.index ["group_id"], name: "index_group_workflows_on_group_id"
    t.index ["workflow_id"], name: "index_group_workflows_on_workflow_id"
  end

  create_table "groups", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.integer "parent_id"
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_groups_on_name"
    t.index ["parent_id", "position"], name: "index_groups_on_parent_id_and_position"
    t.index ["parent_id"], name: "index_groups_on_parent_id"
  end

  create_table "scenarios", force: :cascade do |t|
    t.integer "workflow_id", null: false
    t.integer "user_id", null: false
    t.json "inputs"
    t.json "execution_path"
    t.json "results"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "current_step_index", default: 0, null: false
    t.string "status", default: "active", null: false
    t.integer "stopped_at_step_index"
    t.string "current_node_uuid"
    t.integer "parent_scenario_id"
    t.string "resume_node_uuid"
    t.index ["current_node_uuid"], name: "index_scenarios_on_current_node_uuid"
    t.index ["parent_scenario_id"], name: "index_scenarios_on_parent_scenario_id"
    t.index ["status"], name: "index_scenarios_on_status"
    t.index ["user_id"], name: "index_scenarios_on_user_id"
    t.index ["workflow_id"], name: "index_scenarios_on_workflow_id"
  end

  create_table "templates", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.json "workflow_data"
    t.string "category"
    t.boolean "is_public", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_templates_on_category"
    t.index ["is_public"], name: "index_templates_on_is_public"
  end

  create_table "user_groups", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "group_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_user_groups_on_group_id"
    t.index ["user_id", "group_id"], name: "index_user_groups_on_user_and_group", unique: true
    t.index ["user_id"], name: "index_user_groups_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "role", default: "user", null: false
    t.string "display_name", limit: 50
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "locked_at"
    t.string "unlock_token"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["role"], name: "index_users_on_role"
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  create_table "workflows", force: :cascade do |t|
    t.string "title", null: false
    t.text "description"
    t.json "steps"
    t.integer "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "is_public", default: false, null: false
    t.string "status", default: "published", null: false
    t.datetime "draft_expires_at"
    t.integer "lock_version", default: 0, null: false
    t.boolean "graph_mode", default: false, null: false
    t.string "start_node_uuid"
    t.index ["created_at"], name: "index_workflows_on_created_at"
    t.index ["draft_expires_at"], name: "index_workflows_on_draft_expires_at"
    t.index ["graph_mode"], name: "index_workflows_on_graph_mode"
    t.index ["is_public"], name: "index_workflows_on_is_public"
    t.index ["status", "user_id"], name: "index_workflows_on_status_and_user_id"
    t.index ["status"], name: "index_workflows_on_status"
    t.index ["user_id"], name: "index_workflows_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "folders", "groups"
  add_foreign_key "group_workflows", "folders"
  add_foreign_key "group_workflows", "groups"
  add_foreign_key "group_workflows", "workflows"
  add_foreign_key "scenarios", "scenarios", column: "parent_scenario_id", on_delete: :nullify
  add_foreign_key "scenarios", "users"
  add_foreign_key "scenarios", "workflows"
  add_foreign_key "user_groups", "groups"
  add_foreign_key "user_groups", "users"
  add_foreign_key "workflows", "users"
end
