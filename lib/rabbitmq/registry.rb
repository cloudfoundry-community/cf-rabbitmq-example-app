require_relative 'adapters/amqp'
require_relative 'adapters/management'
require_relative 'adapters/mqtt'
require_relative 'adapters/stomp'
require_relative 'adapters/websocket'

module RabbitMQ
  module Registry
    ADAPTERS = {
      'amqp' => Adapters::AMQP,
      'amqps' => Adapters::AMQP,
      'management' => Adapters::Management,
      'management_tls' => Adapters::Management,
      'mqtt' => Adapters::MQTT,
      'mqtts' => Adapters::MQTT,
      'stomp' => Adapters::Stomp,
      'stomps' => Adapters::Stomp,
      'web_mqtt' => Adapters::WebMQTT,
      'web_mqtt_tls' => Adapters::WebMQTT,
      'web_stomp' => Adapters::WebStomp,
      'web_stomp_tls' => Adapters::WebStomp
    }.freeze

    def self.adapter_for(name)
      ADAPTERS[name.to_s]
    end
  end
end
