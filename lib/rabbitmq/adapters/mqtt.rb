require 'mqtt'
require 'securerandom'
require 'digest/sha1'
require 'timeout'
require_relative 'base'

module RabbitMQ
  module Adapters
    # MQTT via ruby-mqtt (TCP only).
    #
    # The MQTT plugin takes no vhost from the connection - the Resolver has
    # already folded it into the username as "vhost:user".
    #
    # RabbitMQ closes the older connection when a second client connects
    # with a duplicate client_id, so a single fixed id would make two
    # concurrent requests to the SAME app instance evict each other - not
    # merely two instances. A stable id is nevertheless what lets a POST
    # subscribe and a later GET consume find the same session. The two
    # requirements genuinely conflict, so this adapter offers all three
    # common strategies and lets the caller choose. The tradeoff is the
    # lesson - this is an example app.
    class MQTT < Base
      READ_TIMEOUT = 2

      STRATEGIES = %w[serialized per-queue per-request].freeze

      # Guards only the per-instance client_id resource under the
      # 'serialized' strategy - it holds no message or queue data, so it
      # does not violate the no-process-local-state rule.
      MUTEX = Mutex.new

      def initialize(endpoint, strategy: 'serialized')
        super(endpoint)
        @strategy = STRATEGIES.include?(strategy) ? strategy : 'serialized'
      end

      attr_reader :strategy

      def connection_options(queue = nil)
        {
          host: endpoint.host,
          port: endpoint.port,
          ssl: endpoint.tls,
          username: endpoint.username,
          password: endpoint.password,
          client_id: client_id(queue),
          clean_session: false
        }
      end

      # ruby-mqtt enforces MQTT 3.1's 23-byte client identifier limit at
      # serialisation time regardless of protocol version - it raises
      # rather than truncating. "cf-rabbitmq-example-app-" alone is
      # already 25 bytes, so the prefix has to be short by construction,
      # and a queue name (unbounded, caller-supplied) can never be
      # concatenated in directly - it is hashed to a fixed-length token
      # instead.
      APP_ID = 'cfrmq'

      # RabbitMQ evicts the older connection on a duplicate client_id, so
      # the id determines both concurrency safety and whether a prior
      # subscribe is still visible to a later consume.
      def client_id(queue = nil)
        base = "#{APP_ID}-#{ENV['CF_INSTANCE_INDEX'] || '0'}"
        case strategy
        when 'per-queue'   then "#{base}-#{queue_token(queue)}"
        when 'per-request' then "#{base}-#{SecureRandom.hex(4)}"
        else base
        end
      end

      def ping
        with_strategy do
          ::MQTT::Client.connect(**connection_options) { |_c| nil }
          [200, 'OK']
        end
      end

      # A persistent session makes the subscription (and its backing queue)
      # survive disconnect, which is what makes a later consume possible.
      def declare(name)
        with_strategy do
          ::MQTT::Client.connect(**connection_options(name)) do |client|
            client.subscribe(name => 1)
          end
          [201, 'SUCCESS']
        end
      end

      def publish(name, data)
        with_strategy do
          ::MQTT::Client.connect(**connection_options(name)) do |client|
            client.publish(name, data, false, 1)
          end
          [201, 'SUCCESS']
        end
      end

      # per-request cannot see a prior subscribe, because its client_id is
      # unique to this request - an empty result there would be
      # indistinguishable from an empty queue, which is the wrong lesson
      # for an example app to teach silently. Refuse explicitly instead.
      def consume(name)
        if strategy == 'per-request'
          return [409, 'STRATEGY-CONFLICT: per-request cannot see a prior ' \
                       'subscribe; use serialized or per-queue']
        end

        with_strategy { consume_once(name) }
      end

      private

      # Fixed-length regardless of queue name length, so an arbitrarily
      # long (caller-supplied) queue name can never push the client_id
      # past MQTT's 23-byte wire limit.
      def queue_token(queue)
        Digest::SHA1.hexdigest(queue.to_s)[0, 8]
      end

      # Only MQTT serializes, and only under the default strategy. Every
      # other protocol stays fully concurrent.
      def with_strategy
        strategy == 'serialized' ? MUTEX.synchronize { yield } : yield
      end

      # MQTT::Client.connect(&block) always returns the client itself, not
      # the block's value (see MQTT::Client.connect), so the only way to
      # carry the received message out of the block is a non-local return
      # from this method - `return` inside the block is intentional, not
      # a typo, and it still runs Client#connect's own `ensure disconnect`
      # as the stack unwinds.
      def consume_once(name)
        ::MQTT::Client.connect(**connection_options(name)) do |client|
          client.subscribe(name => 1)
          Timeout.timeout(READ_TIMEOUT) do
            _topic, message = client.get
            return [200, "#{message}\n"]
          end
        end
        [204, '']
      rescue Timeout::Error
        [204, '']
      end
    end
  end
end
