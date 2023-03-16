module Blazer
  class Check < Record
    belongs_to :creator, optional: true, class_name: Blazer.user_class.to_s if Blazer.user_class
    belongs_to :query

    validates :query_id, presence: true
    validate :validate_emails
    validate :validate_variables, if: -> { query_id_changed? }

    before_validation :set_state
    before_validation :fix_emails

    def split_emails
      emails.to_s.downcase.split(",").map(&:strip)
    end

    def split_slack_channels
      if Blazer.slack?
        slack_channels.to_s.downcase.split(",").map(&:strip)
      else
        []
      end
    end

    def update_state(result)
      check_type =
        if respond_to?(:check_type)
          self.check_type
        elsif respond_to?(:invert)
          invert ? "missing_data" : "bad_data"
        else
          "bad_data"
        end

      message = result.error

      self.state =
        if result.timed_out?
          "timed out"
        elsif result.error
          "error"
        elsif check_type == "anomaly"
          anomaly, message = result.detect_anomaly
          if anomaly.nil?
            "error"
          elsif anomaly
            "failing"
          else
            "passing"
          end
        elsif check_type == "alert_notifications"
          if result.rows.any?
            "rows_found"
          else
            "none"
          end
        elsif result.rows.any?
          check_type == "missing_data" ? "passing" : "failing"
        else
          check_type == "missing_data" ? "failing" : "passing"
        end

      finished_time = Time.now 
      self.last_run_at = finished_time if respond_to?(:last_run_at=)
      self.message = message if respond_to?(:message=)

      if respond_to?(:timeouts=)
        if result.timed_out?
          self.timeouts += 1
          self.state = "disabled" if timeouts >= 3
        else
          self.timeouts = 0
        end
      end

      # do not notify on creation, except when not passing
      if check_type == "alert_notifications" && state == "rows_found"

        #Update check params with last run date time
        ck_parms = self.check_params
        ck_parms['last_run_at'] = finished_time.utc
        self.check_params = ck_parms

        # Keep track of the set of users per check alert
        user_uuids = []

        result.rows.each do |r|

          record_values = result.columns.each_with_index.map { |col, idx| [col.to_sym, r[idx]]}.to_h

          # Only send one alert event per user
          unless user_uuids.include?(record_values[:user_uuid])

            user_uuids << record_values[:user_uuid]

            action_context = {
              utc_time:  Time.now.utc.to_s,
              controller: 'EventController',
              action: 'trigger_user_alert_notification',
              user_uuid:  record_values[:user_uuid],
              event_object: "#{self.class.name}/#{self.id}",
              event_object_data: record_values
            }

            EventPublisher.new.publish_event(action_context)
            
          end

        end

        self.state = "#{user_uuids.size}_rows_found"

      elsif (state_was != "new" || state != "passing") && state != state_was
        Blazer::CheckMailer.state_change(self, state, state_was, result.rows.size, message, result.columns, result.rows.first(10).as_json, result.column_types, check_type).deliver_now if emails.present?
        Blazer::SlackNotifier.state_change(self, state, state_was, result.rows.size, message, check_type)
      
      end
      save! if changed?
    end

    private

      def set_state
        self.state ||= "new"
      end

      def fix_emails
        # some people like doing ; instead of ,
        # but we know what they mean, so let's fix it
        # also, some people like to use whitespace
        if emails.present?
          self.emails = emails.strip.gsub(/[;\s]/, ",").gsub(/,+/, ", ")
        end
      end

      def validate_emails
        unless split_emails.all? { |e| e =~ /\A\S+@\S+\.\S+\z/ }
          errors.add(:base, "Invalid emails")
        end
      end

      def validate_variables 
        if query.variables.any? && check_type != 'alert_notifications'
          errors.add(:base, "Query can't have variables")
        end
      end
  end
end
