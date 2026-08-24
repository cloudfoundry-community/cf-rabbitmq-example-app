require 'bunny'
require_relative 'adapters/amqp'

module RabbitMQ
  # Demonstrates rabbitmq_consistent_hash_exchange, which the Blacksmith kit
  # enables by default. Publishing N messages with distinct routing keys
  # spreads them across the bound queues rather than fanning out.
  class ConsistentHash
    EXCHANGE_NAME = 'consistent-hash-demo'.freeze
    QUEUE_PREFIX = 'consistent-hash-demo'.freeze
    PLUGIN_NAME = 'rabbitmq_consistent_hash_exchange'.freeze

    # QUEUE_PREFIX doubles as the exchange name, so a plain
    # String#start_with? filter in #distribution would also sweep in any
    # queue that merely shares the prefix - including one this class
    # never created, e.g. a queue declared straight through the generic
    # POST /queues route and happening to be named
    # "consistent-hash-demo-scratch". queue_name only ever emits a
    # numeric suffix, so scope the match to that exact shape.
    QUEUE_NAME_PATTERN = /\A#{Regexp.escape(QUEUE_PREFIX)}-\d+\z/.freeze

    # Raised when the broker rejects the x-consistent-hash exchange type -
    # the plugin is in the Blacksmith kit's default enable list but is not
    # guaranteed present on every broker this app might point at.
    class PluginMissing < StandardError
      def initialize
        super("#{PLUGIN_NAME} plugin is not enabled on this broker")
      end
    end

    def initialize(endpoint, management)
      @endpoint = endpoint
      @management = management
    end

    def queue_name(index)
      "#{QUEUE_PREFIX}-#{index}"
    end

    def run(queues: 3, messages: 100)
      connection = Bunny.new(**Adapters::AMQP.new(@endpoint).connection_options)
      connection.start
      channel = connection.create_channel

      exchange = declare_exchange(channel)
      queues.times do |i|
        channel.queue(queue_name(i), durable: false).bind(exchange, routing_key: '1')
      end

      messages.times { |i| exchange.publish("message-#{i}", routing_key: i.to_s) }

      { 'queues' => queues, 'published' => messages }
    ensure
      connection&.close
    end

    def distribution
      @management.queues
                 .select { |q| q['name'].to_s.match?(QUEUE_NAME_PATTERN) }
                 .to_h { |q| [q['name'], q['messages']] }
    end

    def total
      distribution.values.sum
    end

    private

    # Scoped to just the exchange declaration - other channel-level errors
    # further down (e.g. a precondition failure on a queue bind) are real
    # faults, not a missing plugin, and should not be misreported as one.
    def declare_exchange(channel)
      channel.exchange(EXCHANGE_NAME, type: 'x-consistent-hash', durable: false)
    rescue Bunny::ChannelLevelException
      raise PluginMissing
    end
  end
end
