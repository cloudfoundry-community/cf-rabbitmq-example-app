require_relative 'adapters/amqp'
require_relative 'adapters/management'

module RabbitMQ
  module Registry
    ADAPTERS = {
      'amqp' => Adapters::AMQP,
      'amqps' => Adapters::AMQP,
      'management' => Adapters::Management,
      'management_tls' => Adapters::Management
    }.freeze

    def self.adapter_for(name)
      ADAPTERS[name.to_s]
    end
  end
end
