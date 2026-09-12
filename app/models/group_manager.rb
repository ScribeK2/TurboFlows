# An administrator's grant (spec 2026-09-12): this person sees Analytics for the
# group's members and its sub-teams. Not a membership. Nothing a person does
# themselves adds or removes one, and it does not change their role.
class GroupManager < ApplicationRecord
  belongs_to :group
  belongs_to :user

  validates :user_id, uniqueness: { scope: :group_id }
  validate :group_is_not_global

  private

  # A manager of Global would see everyone's runs, which is what Admin is for.
  def group_is_not_global
    errors.add(:group, "Global has no managers — administrators already see everyone") if group&.global?
  end
end
