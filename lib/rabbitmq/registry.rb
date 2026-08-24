require_relative 'adapters/amqp'
require_relative 'adapters/management'
require_relative 'adapters/mqtt'

module RabbitMQ
  module Registry
    ADAPTERS = {
      'amqp' => Adapters::AMQP,
      'amqps' => Adapters::AMQP,
      'management' => Adapters::Management,
      'management_tls' => Adapters::Management,
      'mqtt' => Adapters::MQTT,
      'mqtts' => Adapters::MQTT
    }.freeze

    def self.adapter_for(name)
      ADAPTERS[name.to_s]
    end
  end
end
