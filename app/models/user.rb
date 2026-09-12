class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :lockable, :timeoutable

  has_many :workflows, dependent: :destroy
  has_many :scenarios, dependent: :destroy
  has_many :user_workflow_pins, dependent: :destroy
  has_many :pinned_workflows,
           -> { order("user_workflow_pins.created_at DESC") },
           through: :user_workflow_pins,
           source: :workflow
  has_many :user_groups, dependent: :destroy
  has_many :groups, through: :user_groups
  has_many :group_managers, dependent: :destroy
  has_many :managed_groups, through: :group_managers, source: :group

  # String-backed enum — maps to existing column values with no migration needed.
  # :regular maps to DB value "user" to avoid User.user naming collision.
  enum :role, { admin: "admin", editor: "editor", regular: "user" }, default: "user"

  # The admin role selects and the actions that consume them read from these two
  # constants, so a rendered <option> and the validation that accepts it cannot
  # disagree. They deliberately speak in enum **keys**: "regular" is the public
  # name and "user" is the column value, and the enum maps between them on write.
  #
  # This replaced a `ROLES = %w[admin editor user]` list of column *values*. The
  # row select was built from the keys and validated against that list, so
  # "regular" never matched and demoting a single user to Regular was impossible
  # — while the bulk dialog, which hardcoded "user", worked. Two lists, one rule.
  ASSIGNABLE_ROLES = roles.keys.freeze
  ROLE_OPTIONS = roles.keys.map { |key| [key.capitalize, key] }.freeze

  # -- Scopes for admin filtering --
  scope :search_by, lambda { |query|
    return all if query.blank?

    search_term = "%#{sanitize_sql_like(query)}%"
    case_insensitive_like("email", search_term)
      .or(case_insensitive_like("display_name", search_term))
  }

  scope :by_role, lambda { |role|
    where(role: role)
  }

  scope :by_group, lambda { |group_id|
    joins(:user_groups).where(user_groups: { group_id: group_id }).distinct
  }

  # Accounts that can sign in and see almost nothing. A Regular or Editor user
  # with no group sees only Global workflows (Workflow.visible_to), so each one is
  # waiting on an administrator. Admins see everything regardless, and a
  # deactivated account cannot sign in, so neither belongs here.
  scope :awaiting_groups, lambda {
    where(role: %w[regular editor], deactivated_at: nil).where.missing(:user_groups)
  }

  # awaiting_groups for one account. The two must agree; user_self_join_test.rb
  # holds them together.
  def awaiting_groups?
    !admin? && !deactivated? && !user_groups.exists?
  end

  # Sortable columns for the admin users table. Every column gets both
  # directions by construction — the previous case statement had role_asc with
  # no role_desc, and reached created_at_desc only by falling through `else`,
  # which is not something clickable column headers can express.
  #
  # Groups and Workflows are deliberately absent: they are association counts,
  # so ordering by them needs a join or a counter cache and the N+1 exposure
  # that comes with it.
  SORT_COLUMNS = %w[email role created_at].freeze
  SORT_OPTIONS = SORT_COLUMNS.flat_map { |c| ["#{c}_asc", "#{c}_desc"] }.freeze
  DEFAULT_SORT = "created_at_desc".freeze

  scope :sorted_by, lambda { |field|
    key = SORT_OPTIONS.include?(field) ? field : DEFAULT_SORT
    column, direction = key.match(/\A(.+)_(asc|desc)\z/).captures
    order(column => direction)
  }

  # Devise notifications are queued, not delivered inline — see
  # send_devise_notification below.
  after_commit :send_pending_devise_notifications

  normalizes :display_name, with: ->(name) { name.strip }
  # Canonicalize to the Rails-friendly TimeZone name (e.g., "Pacific Time (US & Canada)")
  # so f.time_zone_select can pre-select the saved value. Accepts IANA names
  # ("America/Los_Angeles") as input and converts them to the friendly form.
  normalizes :time_zone, with: lambda { |name|
    cleaned = name.to_s.strip
    next cleaned if cleaned.empty?

    ActiveSupport::TimeZone::MAPPING.invert[cleaned] || cleaned
  }

  # Validations
  validates :display_name, length: { maximum: 50 }, allow_blank: true
  validates :time_zone, presence: true
  validate :time_zone_must_be_recognized

  def time_zone_must_be_recognized
    return if time_zone.blank?
    return if ActiveSupport::TimeZone[time_zone]

    errors.add(:time_zone, "is not a recognized time zone")
  end

  # Check if user can create workflows
  # -- Administrative deactivation --
  #
  # Deliberately NOT Devise's `lock_access!`. `unlock_strategy = :both` with
  # `unlock_in = 1.hour` means a lock expires on a timer, so offboarding someone
  # that way silently wore off after an hour, and the listing could not tell a
  # deliberate deactivation from a five-failed-attempts lockout. `deactivated_at`
  # answers only the first question; `locked_at` keeps answering the second.
  def deactivated?
    deactivated_at.present?
  end

  def deactivate!
    return if deactivated?

    update!(deactivated_at: Time.current)
  end

  # Also clears a Devise lockout: an admin putting someone back to work should
  # not have to notice that they were separately locked out by failed logins.
  def reactivate!
    update!(deactivated_at: nil)
    unlock_access! if access_locked?
  end

  # -- Groups --

  # Joins groups on this person's own say (spec 2026-09-11 Q1, Q7). Refuses the
  # whole request if any group is not self-joinable rather than joining the rest:
  # an id the picker never offered is not a mistake to paper over. A group they
  # are already in keeps the origin it has (Q15). Returns the ids newly joined.
  #
  # joinable_ids lets a request that already read the tree pass it in, rather
  # than reading every group again.
  def join_groups!(group_ids, joinable_ids: Group.self_joinable_ids)
    ids = Array(group_ids).compact_blank.map(&:to_i).uniq
    raise Group::NotSelfJoinable if (ids - joinable_ids).any?

    new_ids = ids - user_groups.pluck(:group_id)
    transaction do
      new_ids.each { user_groups.create!(group_id: it, self_joined: true) }
    end
    new_ids
  end

  # Leaves a group on this person's own say (Q8). A group they could not rejoin
  # is left only by an administrator.
  def leave_group!(group)
    raise Group::NotSelfJoinable unless Group.self_joinable_ids.include?(group.id)

    user_groups.find_by!(group_id: group.id).destroy!
  end

  # An administrator's choice of this person's groups: a diff, not a wipe. A
  # membership that stays keeps its self_joined origin (Q15), which the
  # destroy_all-and-recreate this replaced erased on every save.
  def replace_groups!(group_ids)
    ids = Array(group_ids).compact_blank.map(&:to_i).uniq

    transaction do
      user_groups.where.not(group_id: ids).destroy_all
      (ids - user_groups.pluck(:group_id)).each { user_groups.create!(group_id: it) }
    end
  end

  # Devise consults this on every sign-in and on every request for a remembered
  # session, so a deactivated user is turned away rather than merely hidden.
  def active_for_authentication?
    super && !deactivated?
  end

  def inactive_message
    deactivated? ? :deactivated : super
  end

  def can_create_workflows?
    admin? || editor?
  end

  # Check if user can edit workflows
  def can_edit_workflows?
    admin? || editor?
  end

  # Check if user can manage tags
  def can_manage_tags?
    admin? || editor?
  end

  # Check if user can manage templates
  def can_manage_templates?
    admin?
  end

  # Check if user can access admin panel
  def can_access_admin?
    admin?
  end

  # Get groups accessible to this user (admins see all, others see assigned groups)
  def accessible_groups
    admin? ? Group.all : groups
  end

  # Preferred label for displaying the user in the UI
  def display_label
    display_name.presence || email
  end

  # When this person last started a run — simulation or live. There is no
  # sign-in tracking (:trackable is off), and for an agent a run is the activity
  # that matters.
  def last_active_at
    scenarios.maximum(:created_at)
  end

  # Avatar display helpers
  def avatar_initial
    display_label[0].upcase
  end

  AVATAR_COLORS = {
    'admin' => 'avatar--admin',
    'editor' => 'avatar--editor',
    'regular' => 'avatar--regular'
  }.freeze

  AVATAR_BADGE_CLASSES = {
    'admin' => 'badge--admin',
    'editor' => 'badge--editor',
    'regular' => 'badge--regular'
  }.freeze

  def avatar_color_class
    AVATAR_COLORS[role] || AVATAR_COLORS['regular']
  end

  def avatar_role_badge_classes
    AVATAR_BADGE_CLASSES[role] || AVATAR_BADGE_CLASSES['regular']
  end

  # When true, Devise will not send the "password changed" email (used for admin
  # temporary password resets where the password is shown in the UI instead).
  attr_accessor :skip_password_change_notification

  # Skip password-change email when set by admin reset (avoids SMTP in environments
  # where mail is not configured, e.g. Render without SendGrid).
  def send_password_change_notification
    return if skip_password_change_notification

    super
  end

  # Generate a secure temporary password for admin reset
  def generate_temporary_password
    self.skip_password_change_notification = true
    temp_password = SecureRandom.alphanumeric(14) + SecureRandom.random_number(10).to_s + ("A".."Z").to_a.sample
    temp_password = temp_password.chars.shuffle.join
    self.password = temp_password
    self.password_confirmation = temp_password
    save!(validate: false)
    temp_password
  end

  protected

  # Devise delivers with deliver_now by default, inside the request. That put an
  # SMTP round trip on three request paths — the forgot-password submit, a
  # password change, and the fifth failed login, which locks the account and
  # mails unlock instructions — so a slow or unreachable relay became a 500 on
  # the page rather than an email that never arrived.
  #
  # A notification raised while the record still has unsaved changes is held and
  # flushed from after_commit — Devise's documented pattern for deliver_later —
  # so Solid Queue, which writes to its own database, never gets a job that
  # loads the record before its changes land.
  #
  # Note what that does not cover. Inside an after_update, which is where
  # send_password_change_notification fires, changed? is already false, so that
  # one enqueues on the spot, inside the transaction. Rails 8.1 ships
  # enqueue_after_transaction_commit false, so the job can in principle run
  # before the commit; it only reloads the user to render "your password
  # changed", so nothing reads the uncommitted value. Closing that window means
  # enabling enqueue_after_transaction_commit for every job in the app.
  def send_devise_notification(notification, *args)
    if new_record? || changed?
      pending_devise_notifications << [notification, args]
    else
      render_and_send_devise_message(notification, *args)
    end
  end

  private

  def send_pending_devise_notifications
    pending_devise_notifications.each do |notification, args|
      render_and_send_devise_message(notification, *args)
    end
    pending_devise_notifications.clear
  end

  def pending_devise_notifications
    @pending_devise_notifications ||= []
  end

  def render_and_send_devise_message(notification, *)
    devise_mailer.send(notification, self, *).deliver_later
  end
end
