require 'stomp'
require 'timeout'
require_relative 'base'

module RabbitMQ
  module Adapters
    # STOMP via the stomp gem (TCP only).
    #
    # Unlike MQTT, STOMP carries the vhost in the CONNECT frame's host
    # header, so the username is used as-is.
    class Stomp < Base
      READ_TIMEOUT = 2

      # Stomp::Client's own :start_timeout defaults to 0, which the stomp
      # gem treats as "no timeout at all" (Timeout.timeout(0) never fires)
      # - an unreachable broker would hang Stomp::Client.new forever. Bound
      # it explicitly so every request-scoped connection attempt fails
      # instead of hanging the request.
      CONNECT_TIMEOUT = 5

      def connection_options
        {
          connect_headers: {
            'host' => endpoint.vhost,
            'accept-version' => '1.0,1.1,1.2'
          },
          hosts: [{
            login: endpoint.username,
            passcode: endpoint.password,
            host: endpoint.host,
            port: endpoint.port,
            ssl: endpoint.tls
          }],
          reliable: false,
          start_timeout: CONNECT_TIMEOUT
        }
      end

      def destination(name)
        "/queue/#{name}"
      end

      def ping
        with_client { |_client| [200, 'OK'] }
      end

      def declare(name)
        with_client do |client|
          client.subscribe(destination(name)) { |_msg| nil }
          client.unsubscribe(destination(name))
          [201, 'SUCCESS']
        end
      end

      def publish(name, data)
        with_client do |client|
          client.publish(destination(name), data)
          [201, 'SUCCESS']
        end
      end

      def consume(name)
        with_client do |client|
          message = nil
          client.subscribe(destination(name)) { |msg| message = msg }
          begin
            Timeout.timeout(READ_TIMEOUT) { sleep 0.01 until message }
            [200, "#{message.body}\n"]
          rescue Timeout::Error
            [204, '']
          ensure
            client.unsubscribe(destination(name))
          end
        end
      end

      private

      def with_client
        client = ::Stomp::Client.new(connection_options)
        yield client
      ensure
        client&.close
      end
    end
  end
end
