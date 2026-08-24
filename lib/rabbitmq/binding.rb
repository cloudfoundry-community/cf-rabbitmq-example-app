require 'json'

module RabbitMQ
  # Locates the RabbitMQ service credentials inside VCAP_SERVICES.
  #
  # Service labels vary by broker (rabbitmq, p-rabbitmq, p.rabbitmq), so
  # detection is by credential shape rather than by label.
  class Binding
    def self.from_env(env = ENV)
      new(env['VCAP_SERVICES'])
    end

    def initialize(raw)
      @credentials = raw.nil? || raw.empty? ? nil : locate(raw)
    end

    attr_reader :credentials

    def bound?
      !credentials.nil?
    end

    def protocols
      return {} unless bound?

      credentials['protocols'] || {}
    end

    def protocol(name)
      protocols[name.to_s]
    end

    private

    def locate(raw)
      JSON.parse(raw).each_value do |services|
        Array(services).each do |service|
          creds = service['credentials']
          return creds if rabbitmq?(creds)
        end
      end
      nil
    rescue JSON::ParserError
      nil
    end

    # A rabbitmq binding either advertises protocols or carries an AMQP URI.
    def rabbitmq?(creds)
      return false unless creds.is_a?(Hash)
      return true if creds['protocols'].is_a?(Hash)

      Array(creds['uris']).push(creds['uri']).compact.any? { |u| u.start_with?('amqp://', 'amqps://') }
    end
  end
end
