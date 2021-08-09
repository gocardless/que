# frozen_string_literal: true

require "pg"

module Que
  module Adapters
    class ActiveRecord < Base
      AR_UNAVAILABLE_CONNECTION_ERRORS = [
        "::ActiveRecord::ConnectionTimeoutError",
        "::ActiveRecord::ConnectionNotEstablished",
        "::PG::ConnectionBad",
        "::PG::ServerError",
        "::PG::UnableToSend",
      ].freeze

      def checkout
        checkout_activerecord_adapter { |conn| yield conn.raw_connection }
      rescue *AR_UNAVAILABLE_CONNECTION_ERRORS.map(&:constantize) => e
        raise UnavailableConnection, e
      rescue ::ActiveRecord::StatementInvalid => e
        raise e unless AR_UNAVAILABLE_CONNECTION_ERRORS.include?(e.cause.class.to_s)

        # ActiveRecord::StatementInvalid is one of the most generic exceptions AR can
        # raise, so we catch it and only handle the specific nested exceptions.
        raise UnavailableConnection, e.cause
      end

      def wake_worker_after_commit
        # Works with ActiveRecord 3.2 and 4 (possibly earlier, didn't check)
        if in_transaction?
          checkout_activerecord_adapter do |adapter|
            adapter.add_transaction_record(TransactionCallback.new)
          end
        else
          Que.wake!
        end
      end

      def cleanup!
        # ActiveRecord will check out connections to the current thread when
        # queries are executed and not return them to the pool until
        # explicitly requested to. The wisdom of this API is questionable, and
        # it doesn't pose a problem for the typical case of workers using a
        # single PG connection (since we ensure that connection is checked in
        # and checked out responsibly), but since ActiveRecord supports
        # connections to multiple databases, it's easy for people using that
        # feature to unknowingly leak connections to other databases. So, take
        # the additional step of telling ActiveRecord to check in all of the
        # current thread's connections between jobs.
        ::ActiveRecord::Base.clear_active_connections!
      end

      class TransactionCallback
        # rubocop:disable Naming/PredicateName
        def has_transactional_callbacks?
          true
        end
        # rubocop:enable Naming/PredicateName

        def rolledback!(force_restore_state = false, should_run_callbacks = true)
          # no-op
        end

        def committed!(_should_run_callbacks = true)
          Que.wake!
        end

        def before_committed!(*)
          # no-op
        end

        def add_to_transaction
          # no-op.
          #
          # This is called when we're in a nested transaction. Ideally we would
          # `wake!` when the outer transaction gets committed, but that would be
          # a bigger refactor!
        end
      end

      private

      def checkout_activerecord_adapter(&block)
        ::ActiveRecord::Base.connection_pool.with_connection(&block)
      end
    end
  end
end
