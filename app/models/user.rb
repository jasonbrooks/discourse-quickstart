require_dependency 'email'
require_dependency 'email_token'
require_dependency 'trust_level'
require_dependency 'pbkdf2'
require_dependency 'summarize'
require_dependency 'discourse'
require_dependency 'post_destroyer'
require_dependency 'user_name_suggester'
require_dependency 'roleable'
require_dependency 'pretty_text'

class User < ActiveRecord::Base
  include Roleable

  has_many :posts
  has_many :notifications
  has_many :topic_users
  has_many :topics
  has_many :user_open_ids, dependent: :destroy
  has_many :user_actions
  has_many :post_actions
  has_many :email_logs
  has_many :post_timings
  has_many :topic_allowed_users
  has_many :topics_allowed, through: :topic_allowed_users, source: :topic
  has_many :email_tokens
  has_many :views
  has_many :user_visits
  has_many :invites
  has_many :topic_links
  has_many :uploads

  has_one :facebook_user_info, dependent: :destroy
  has_one :twitter_user_info, dependent: :destroy
  has_one :github_user_info, dependent: :destroy
  has_one :cas_user_info, dependent: :destroy
  has_one :oauth2_user_info, dependent: :destroy
  belongs_to :approved_by, class_name: 'User'

  has_many :group_users
  has_many :groups, through: :group_users
  has_many :secure_categories, through: :groups, source: :categories

  has_one :user_search_data

  belongs_to :uploaded_avatar, class_name: 'Upload', dependent: :destroy

  validates_presence_of :username
  validate :username_validator
  validates :email, presence: true, uniqueness: true
  validates :email, email: true, if: :email_changed?
  validate :password_validator

  before_save :cook
  before_save :update_username_lower
  before_save :ensure_password_is_hashed
  after_initialize :add_trust_level
  after_initialize :set_default_email_digest

  after_save :update_tracked_topics

  after_create :create_email_token

  # Whether we need to be sending a system message after creation
  attr_accessor :send_welcome_message

  # This is just used to pass some information into the serializer
  attr_accessor :notification_channel_position

  scope :blocked, -> { where(blocked: true) } # no index
  scope :banned, -> { where('banned_till IS NOT NULL AND banned_till > ?', Time.zone.now) } # no index
  scope :not_banned, -> { where('banned_till IS NULL') }

  module NewTopicDuration
    ALWAYS = -1
    LAST_VISIT = -2
  end

  def self.username_length
    3..15
  end

  def self.username_available?(username)
    lower = username.downcase
    User.where(username_lower: lower).blank?
  end

  EMAIL = %r{([^@]+)@([^\.]+)}

  def self.new_from_params(params)
    user = User.new
    user.name = params[:name]
    user.email = params[:email]
    user.password = params[:password]
    user.username = params[:username]
    user
  end

  def self.suggest_name(email)
    return "" unless email
    name = email.split(/[@\+]/)[0]
    name = name.gsub(".", " ")
    name.titleize
  end

  # Find a user by temporary key, nil if not found or key is invalid
  def self.find_by_temporary_key(key)
    user_id = $redis.get("temporary_key:#{key}")
    if user_id.present?
      where(id: user_id.to_i).first
    end
  end

  def self.find_by_username_or_email(username_or_email)
    conditions = if username_or_email.include?('@')
      { email: Email.downcase(username_or_email) }
    else
      { username_lower: username_or_email.downcase }
    end

    users = User.where(conditions).to_a

    if users.size > 1
      raise Discourse::TooManyMatches
    else
      users.first
    end
  end

  def enqueue_welcome_message(message_type)
    return unless SiteSetting.send_welcome_message?
    Jobs.enqueue(:send_system_message, user_id: id, message_type: message_type)
  end

  def change_username(new_username)
    current_username = self.username
    self.username = new_username

    if current_username.downcase != new_username.downcase && valid?
      DiscourseHub.nickname_operation { DiscourseHub.change_nickname(current_username, new_username) }
    end

    save
  end

  # Use a temporary key to find this user, store it in redis with an expiry
  def temporary_key
    key = SecureRandom.hex(32)
    $redis.setex "temporary_key:#{key}", 1.week, id.to_s
    key
  end


  # tricky, we need our bus to be subscribed from the right spot
  def sync_notification_channel_position
    @unread_notifications_by_type = nil
    self.notification_channel_position = MessageBus.last_id("/notification/#{id}")
  end

  def invited_by
    used_invite = invites.where("redeemed_at is not null").includes(:invited_by).first
    used_invite.try(:invited_by)
  end

  # Approve this user
  def approve(approved_by, send_mail=true)
    self.approved = true

    if Fixnum === approved_by
      self.approved_by_id = approved_by
    else
      self.approved_by = approved_by
    end

    self.approved_at = Time.now

    send_approval_email if save and send_mail
  end

  def self.email_hash(email)
    Digest::MD5.hexdigest(email.strip.downcase)
  end

  def email_hash
    User.email_hash(email)
  end

  def unread_notifications_by_type
    @unread_notifications_by_type ||= notifications.where("id > ? and read = false", seen_notification_id).group(:notification_type).count
  end

  def reload
    @unread_notifications_by_type = nil
    @unread_pms = nil
    super
  end

  def unread_private_messages
    @unread_pms ||= notifications.where("read = false AND notification_type = ?", Notification.types[:private_message]).count
  end

  def unread_notifications
    unread_notifications_by_type.except(Notification.types[:private_message]).values.sum
  end

  def saw_notification_id(notification_id)
    User.where(["id = ? and seen_notification_id < ?", id, notification_id])
        .update_all ["seen_notification_id = ?", notification_id]
  end

  def publish_notifications_state
    MessageBus.publish("/notification/#{id}",
                       {unread_notifications: unread_notifications,
                        unread_private_messages: unread_private_messages},
                       user_ids: [id] # only publish the notification to this user
    )
  end

  # A selection of people to autocomplete on @mention
  def self.mentionable_usernames
    User.select(:username).order('last_posted_at desc').limit(20)
  end

  def password=(password)
    # special case for passwordless accounts
    @raw_password = password unless password.blank?
  end

  # Indicate that this is NOT a passwordless account for the purposes of validation
  def password_required!
    @password_required = true
  end

  def confirm_password?(password)
    return false unless password_hash && salt
    self.password_hash == hash_password(password, salt)
  end

  def seen_before?
    last_seen_at.present?
  end

  def has_visit_record?(date)
    user_visits.where(visited_at: date).first
  end

  def update_visit_record!(date)
    unless has_visit_record?(date)
      update_column(:days_visited, days_visited + 1)
      user_visits.create!(visited_at: date)
    end
  end

  def update_ip_address!(new_ip_address)
    unless ip_address == new_ip_address || new_ip_address.blank?
      update_column(:ip_address, new_ip_address)
    end
  end

  def update_last_seen!(now=nil)
    now ||= Time.zone.now
    now_date = now.to_date

    # Only update last seen once every minute
    redis_key = "user:#{self.id}:#{now_date}"
    if $redis.setnx(redis_key, "1")
      $redis.expire(redis_key, SiteSetting.active_user_rate_limit_secs)

      update_visit_record!(now_date)

      # using update_column to avoid the AR transaction
      # Keep track of our last visit
      if seen_before? && (self.last_seen_at < (now - SiteSetting.previous_visit_timeout_hours.hours))
        previous_visit_at = last_seen_at
        update_column(:previous_visit_at, previous_visit_at)
      end
      update_column(:last_seen_at, now)
    end
  end

  def self.gravatar_template(email)
    email_hash = self.email_hash(email)
    "//www.gravatar.com/avatar/#{email_hash}.png?s={size}&r=pg&d=identicon"
  end

  # Don't pass this up to the client - it's meant for server side use
  # This is used in
  #   - self oneboxes in open graph data
  #   - emails
  def small_avatar_url
    template = avatar_template
    template.gsub("{size}", "45")
  end

  def avatar_template
    if SiteSetting.allow_uploaded_avatars? && use_uploaded_avatar
      # the avatars might take a while to generate
      # so return the url of the original image in the meantime
      uploaded_avatar_template.present? ? uploaded_avatar_template : uploaded_avatar.try(:url)
    else
      User.gravatar_template(email)
    end
  end

  # Updates the denormalized view counts for all users
  def self.update_view_counts

    # NOTE: we only update the counts for users we have seen in the last hour
    #  this avoids a very expensive query that may run on the entire user base
    #  we also ensure we only touch the table if data changes

    # Update denormalized topics_entered
    exec_sql "UPDATE users SET topics_entered = X.c
             FROM
            (SELECT v.user_id,
                    COUNT(DISTINCT parent_id) AS c
             FROM views AS v
             WHERE parent_type = 'Topic'
             GROUP BY v.user_id) AS X
            WHERE
                    X.user_id = users.id AND
                    X.c <> topics_entered AND
                    users.last_seen_at > :seen_at
    ", seen_at: 1.hour.ago

    # Update denormalzied posts_read_count
    exec_sql "UPDATE users SET posts_read_count = X.c
              FROM
              (SELECT pt.user_id,
                      COUNT(*) AS c
               FROM post_timings AS pt
               GROUP BY pt.user_id) AS X
               WHERE X.user_id = users.id AND
                     X.c <> posts_read_count AND
                     users.last_seen_at > :seen_at
    ", seen_at: 1.hour.ago
  end

  # The following count methods are somewhat slow - definitely don't use them in a loop.
  # They might need to be denormalized
  def like_count
    UserAction.where(user_id: id, action_type: UserAction::WAS_LIKED).count
  end

  def post_count
    posts.count
  end

  def flags_given_count
    PostAction.where(user_id: id, post_action_type_id: PostActionType.flag_types.values).count
  end

  def flags_received_count
    posts.includes(:post_actions).where('post_actions.post_action_type_id' => PostActionType.flag_types.values).count
  end

  def private_topics_count
    topics_allowed.where(archetype: Archetype.private_message).count
  end

  def bio_excerpt
    excerpt = PrettyText.excerpt(bio_cooked, 350)
    return excerpt if excerpt.blank? || has_trust_level?(:basic)
    PrettyText.strip_links(excerpt)
  end

  def bio_processed
    return bio_cooked if bio_cooked.blank? || has_trust_level?(:basic)
    PrettyText.strip_links(bio_cooked)
  end

  def delete_all_posts!(guardian)
    raise Discourse::InvalidAccess unless guardian.can_delete_all_posts? self

    posts.order("post_number desc").each do |p|
      PostDestroyer.new(guardian.user, p).destroy
    end
  end

  def is_banned?
    banned_till && banned_till > DateTime.now
  end

  # Use this helper to determine if the user has a particular trust level.
  # Takes into account admin, etc.
  def has_trust_level?(level)
    raise "Invalid trust level #{level}" unless TrustLevel.valid_level?(level)
    admin? || moderator? || TrustLevel.compare(trust_level, level)
  end

  # a touch faster than automatic
  def admin?
    admin
  end

  def change_trust_level!(level)
    raise "Invalid trust level #{level}" unless TrustLevel.valid_level?(level)
    self.trust_level = TrustLevel.levels[level]
    transaction do
      self.save!
      Group.user_trust_level_change!(self.id, self.trust_level)
    end
  end

  def guardian
    Guardian.new(self)
  end

  def username_format_validator
    UsernameValidator.perform_validation(self, 'username')
  end

  def email_confirmed?
    email_tokens.where(email: email, confirmed: true).present? || email_tokens.empty?
  end

  def activate
    email_token = self.email_tokens.active.first
    if email_token
      EmailToken.confirm(email_token.token)
    else
      self.active = true
      save
    end
  end

  def deactivate
    self.active = false
    save
  end

  def treat_as_new_topic_start_date
    duration = new_topic_duration_minutes || SiteSetting.new_topic_duration_minutes
    case duration
      when User::NewTopicDuration::ALWAYS
        created_at
      when User::NewTopicDuration::LAST_VISIT
        previous_visit_at || created_at
      else
        duration.minutes.ago
    end
  end

  MAX_TIME_READ_DIFF = 100
  # attempt to add total read time to user based on previous time this was called
  def update_time_read!
    last_seen_key = "user-last-seen:#{id}"
    last_seen = $redis.get(last_seen_key)
    if last_seen.present?
      diff = (Time.now.to_f - last_seen.to_f).round
      if diff > 0 && diff < MAX_TIME_READ_DIFF
        User.where(id: id, time_read: time_read).update_all ["time_read = time_read + ?", diff]
      end
    end
    $redis.set(last_seen_key, Time.now.to_f)
  end

  def readable_name
    return "#{name} (#{username})" if name.present? && name != username
    username
  end

  def bio_summary
    return nil unless bio_cooked.present?
    Summarize.new(bio_cooked).summary
  end

  def self.count_by_signup_date(sinceDaysAgo=30)
    where('created_at > ?', sinceDaysAgo.days.ago).group('date(created_at)').order('date(created_at)').count
  end

  def self.counts_by_trust_level
    group('trust_level').count
  end

  def update_topic_reply_count
    self.topic_reply_count =
        Topic
        .where(['id in (
              SELECT topic_id FROM posts p
              JOIN topics t2 ON t2.id = p.topic_id
              WHERE p.deleted_at IS NULL AND
                t2.user_id <> p.user_id AND
                p.user_id = ?
              )', self.id])
        .count
  end

  def secure_category_ids
    cats = self.staff? ? Category.select(:id).where(read_restricted: true) : secure_categories.select('categories.id').references(:categories)
    cats.map { |c| c.id }.sort
  end

  def topic_create_allowed_category_ids
    Category.topic_create_allowed(self.id).select(:id)
  end

  # Flag all posts from a user as spam
  def flag_linked_posts_as_spam
    admin = Discourse.system_user
    topic_links.includes(:post).each do |tl|
      begin
        PostAction.act(admin, tl.post, PostActionType.types[:spam])
      rescue PostAction::AlreadyActed
        # If the user has already acted, just ignore it
      end
    end
  end

  def has_uploaded_avatar
    uploaded_avatar.present?
  end

  protected

  def cook
    if bio_raw.present?
      self.bio_cooked = PrettyText.cook(bio_raw) if bio_raw_changed?
    else
      self.bio_cooked = nil
    end
  end

  def update_tracked_topics
    return unless auto_track_topics_after_msecs_changed?

    where_conditions = {notifications_reason_id: nil, user_id: id}
    if auto_track_topics_after_msecs < 0
      TopicUser.where(where_conditions).update_all({notification_level: TopicUser.notification_levels[:regular]})
    else
      TopicUser.where(where_conditions).update_all(["notification_level = CASE WHEN total_msecs_viewed < ? THEN ? ELSE ? END",
                            auto_track_topics_after_msecs, TopicUser.notification_levels[:regular], TopicUser.notification_levels[:tracking]])
    end
  end

  def create_email_token
    email_tokens.create(email: email)
  end

  def ensure_password_is_hashed
    if @raw_password
      self.salt = SecureRandom.hex(16)
      self.password_hash = hash_password(@raw_password, salt)
    end
  end

  def hash_password(password, salt)
    Pbkdf2.hash_password(password, salt, Rails.configuration.pbkdf2_iterations, Rails.configuration.pbkdf2_algorithm)
  end

  def add_trust_level
    # there is a possiblity we did not load trust level column, skip it
    return unless has_attribute? :trust_level
    self.trust_level ||= SiteSetting.default_trust_level
  end

  def update_username_lower
    self.username_lower = username.downcase
  end

  def username_validator
    username_format_validator || begin
      lower = username.downcase
      existing = User.where(username_lower: lower).first
      if username_changed? && existing && existing.id != self.id
        errors.add(:username, I18n.t(:'user.username.unique'))
      end
    end
  end

  def password_validator
    if (@raw_password && @raw_password.length < 6) || (@password_required && !@raw_password)
      errors.add(:password, "must be 6 letters or longer")
    end
  end

  def send_approval_email
    Jobs.enqueue(:user_email,
      type: :signup_after_approval,
      user_id: id,
      email_token: email_tokens.first.token
    )
  end

  def set_default_email_digest
    if has_attribute?(:email_digests) && self.email_digests.nil?
      if SiteSetting.default_digest_email_frequency.blank?
        self.email_digests = false
      else
        self.email_digests = true
        self.digest_after_days ||= SiteSetting.default_digest_email_frequency.to_i if has_attribute?(:digest_after_days)
      end
    end
  end

  private

end

# == Schema Information
#
# Table name: users
#
#  id                            :integer          not null, primary key
#  username                      :string(20)       not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#  name                          :string(255)
#  bio_raw                       :text
#  seen_notification_id          :integer          default(0), not null
#  last_posted_at                :datetime
#  email                         :string(256)      not null
#  password_hash                 :string(64)
#  salt                          :string(32)
#  active                        :boolean
#  username_lower                :string(20)       not null
#  auth_token                    :string(32)
#  last_seen_at                  :datetime
#  website                       :string(255)
#  admin                         :boolean          default(FALSE), not null
#  last_emailed_at               :datetime
#  email_digests                 :boolean          not null
#  trust_level                   :integer          not null
#  bio_cooked                    :text
#  email_private_messages        :boolean          default(TRUE)
#  email_direct                  :boolean          default(TRUE), not null
#  approved                      :boolean          default(FALSE), not null
#  approved_by_id                :integer
#  approved_at                   :datetime
#  topics_entered                :integer          default(0), not null
#  posts_read_count              :integer          default(0), not null
#  digest_after_days             :integer
#  previous_visit_at             :datetime
#  banned_at                     :datetime
#  banned_till                   :datetime
#  date_of_birth                 :date
#  auto_track_topics_after_msecs :integer
#  views                         :integer          default(0), not null
#  flag_level                    :integer          default(0), not null
#  time_read                     :integer          default(0), not null
#  days_visited                  :integer          default(0), not null
#  ip_address                    :string
#  new_topic_duration_minutes    :integer
#  external_links_in_new_tab     :boolean          default(FALSE), not null
#  enable_quoting                :boolean          default(TRUE), not null
#  moderator                     :boolean          default(FALSE)
#  likes_given                   :integer          default(0), not null
#  likes_received                :integer          default(0), not null
#  topic_reply_count             :integer          default(0), not null
#  blocked                       :boolean          default(FALSE)
#  dynamic_favicon               :boolean          default(FALSE), not null
#  title                         :string(255)
#  use_uploaded_avatar           :boolean          default(FALSE)
#  uploaded_avatar_template      :string(255)
#  uploaded_avatar_id            :integer
#
# Indexes
#
#  index_users_on_auth_token      (auth_token)
#  index_users_on_email           (email) UNIQUE
#  index_users_on_last_posted_at  (last_posted_at)
#  index_users_on_username        (username) UNIQUE
#  index_users_on_username_lower  (username_lower) UNIQUE
#

