# Self-join (spec 2026-09-11 Q1, Q9). A group is joinable unless an administrator
# says only they add people, and a membership records whether its person made it.
# Every membership that exists today was made by an administrator, so false is
# true of all of them.
class AddSelfJoinToGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :groups, :admins_add_members, :boolean, default: false, null: false
    add_column :user_groups, :self_joined, :boolean, default: false, null: false
  end
end
