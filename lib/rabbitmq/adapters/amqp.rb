require 'bunny'
require_relative 'base'

module RabbitMQ
  module Adapters
    class AMQP < Base
      # Bunny needs :tls and :port explicitly. Passing only :addresses
      # defaults to 5672 and never negotiates TLS - the defect this fixes.
      def connection_options
        {
          host: endpoint.host,
          port: endpoint.port,
          tls: endpoint.tls,
          verify_peer: endpoint.verify_peer?,
          username: endpoint.username,
          password: endpoint.password,
          vhost: endpoint.vhost
        }
      end

      def ping
        with_channel { |_ch| [200, 'OK'] }
      end

      def declare(name)
        with_channel do |ch|
          ch.queue(name, durable: false)
          [201, 'SUCCESS']
        end
      end

      # passive: true requires the queue to already exist rather than
      # creating it - PUT is publish-to-existing, not declare-on-demand.
      # Declaration is POST /queues' job (#declare); without passive here,
      # a PUT to a queue nobody declared would silently create it and
      # return 201 instead of the 404 the route contract promises.
      def publish(name, data)
        with_channel do |ch|
          ch.queue(name, durable: false, passive: true)
          ch.default_exchange.publish(data, routing_key: name, content_type: 'text/plain')
          [201, 'SUCCESS']
        end
      rescue Bunny::NotFound
        raise QueueNotFound, name
      end

      # basic_get keeps the app stateless. A missing queue raises
      # Bunny::NotFound (broker 404), which maps to the 404 the route
      # contract already promises.
      def consume(name)
        with_channel do |ch|
          queue = ch.queue(name, durable: false, passive: true)
          _delivery, _props, payload = queue.pop(manual_ack: false)
          payload.nil? ? [204, ''] : [200, "#{payload}\n"]
        end
      rescue Bunny::NotFound
        raise QueueNotFound, name
      end

      private

      def with_channel
        connection = Bunny.new(**connection_options)
        connection.start
        channel = connection.create_channel
        yield channel
      ensure
        close_quietly(connection)
      end

      # Closing a connection that never finished opening makes Bunny try to
      # write a Close frame down a socket that is already gone, and the
      # exception that raises from `ensure` REPLACES whatever the method was
      # about to return or raise. That is how a TLS failure with a perfectly
      # clear message from Bunny - "certificate verify failed (self-signed
      # certificate in certificate chain)" - reached the operator as
      # "ERR:SSL_write", and how a hostname mismatch reached them as a bare
      # "ERR:Timeout::Error". A failure to close is never the interesting
      # failure; the one being reported is.
      def close_quietly(connection)
        connection&.close
      rescue StandardError
        nil
      end
    end
  end
end
