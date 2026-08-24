require 'websocket-client-simple'
require 'mqtt'
require 'timeout'
require_relative 'base'

module RabbitMQ
  module Adapters
    # No Ruby client speaks MQTT or STOMP over WebSocket, so these adapters
    # verify connectivity rather than carry messages: a WebSocket upgrade
    # with the correct subprotocol, then a protocol-level CONNECT exchange.
    # That proves listener, subprotocol AND credentials - a bare 101 would
    # prove only the listener.
    #
    # Publish and consume live in the browser demo pages (a later task).
    class WebSocket < Base
      HANDSHAKE_TIMEOUT = 5

      def url
        "#{endpoint.tls ? 'wss' : 'ws'}://#{endpoint.host}:#{endpoint.port}/ws"
      end

      def subprotocol
        raise NotImplementedError
      end

      def ping
        frame = nil
        error = nil
        socket = nil

        # Client::Simple::Client#connect opens the TCPSocket synchronously,
        # in this thread, before it ever starts the background reader -
        # an unreachable host blocks *there*, not in the poll loop below.
        # Both have to be inside the same Timeout.timeout, or a broker
        # that never accepts the connection hangs the request for however
        # long the OS takes to give up on the TCP handshake (tens of
        # seconds to unbounded, depending on the network).
        Timeout.timeout(HANDSHAKE_TIMEOUT) do
          # Handlers are registered via the connect block, which runs
          # them *before* Client#connect is called. Client#connect starts
          # a background thread that begins reading the socket (and can
          # emit :open) immediately, before that call even returns - a
          # handler attached afterwards, on the returned client, can race
          # and miss it.
          #
          # `socket` is captured from the block argument, not from
          # Simple.connect's return value: the module method only returns
          # once Client#connect finishes, and Client#connect can raise
          # Timeout::Error from inside itself (TLS handshake, or the
          # blocking handshake write) after it has already opened the
          # TCPSocket/SSLSocket and spawned the reader thread. Capturing
          # the return value would leave that half-built client - live
          # socket, live thread looping a read with nobody to stop it -
          # unreachable, since the assignment would never run. The block
          # runs before any of that I/O, so it always gets a handle.
          ::WebSocket::Client::Simple.connect(
            url, headers: { 'Sec-WebSocket-Protocol' => subprotocol }
          ) do |client|
            socket = client
            client.on(:open) { client.send(connect_frame, type: frame_type) }
            client.on(:message) { |msg| frame = msg.data }
            client.on(:error) { |e| error = e }
          end

          sleep 0.05 until frame || error
        end

        return [502, "ERR:#{error.message}"] if error

        acknowledged?(frame) ? [200, 'OK'] : [502, 'ERR:unexpected handshake response']
      rescue Timeout::Error
        [504, 'ERR:no handshake response']
      ensure
        socket&.close
      end

      def declare(name)
        browser_only(name)
      end

      def publish(name, _data)
        browser_only(name)
      end

      def consume(name)
        browser_only(name)
      end

      private

      def browser_only(_name)
        [501, 'NOT-SUPPORTED: no Ruby client speaks this protocol over ' \
              "WebSocket; use #{demo_path} in a browser"]
      end

      def demo_path
        raise NotImplementedError
      end

      def frame_type
        :text
      end

      def connect_frame
        raise NotImplementedError
      end

      def acknowledged?(_frame)
        raise NotImplementedError
      end
    end

    class WebMQTT < WebSocket
      def subprotocol
        'mqtt'
      end

      private

      def demo_path
        '/web-mqtt/demo'
      end

      def frame_type
        :binary
      end

      # ruby-mqtt's packet codec gives us CONNECT/CONNACK without needing a
      # WebSocket-capable MQTT client. #to_s on a packet returns the full
      # wire-format bytes, not a description - MQTT::Packet.parse accepts
      # exactly what it produces.
      #
      # ruby-mqtt enforces MQTT 3.1's 23-byte client identifier limit at
      # serialisation time regardless of protocol version - a longer id
      # raises rather than truncating, so this stays well under it.
      def connect_frame
        ::MQTT::Packet::Connect.new(
          client_id: "cfrmq-ws-#{ENV['CF_INSTANCE_INDEX'] || '0'}",
          username: endpoint.username,
          password: endpoint.password,
          clean_session: true
        ).to_s
      end

      # MQTT::Exception (and ProtocolException, raised by .parse on a
      # malformed frame) subclasses bare ::Exception, not StandardError -
      # rescuing only StandardError here would let a garbled response
      # escape uncaught instead of being reported as a failed handshake.
      def acknowledged?(frame)
        packet = ::MQTT::Packet.parse(frame)
        packet.is_a?(::MQTT::Packet::Connack) && packet.return_code.zero?
      rescue StandardError, ::MQTT::Exception
        false
      end
    end

    class WebStomp < WebSocket
      def subprotocol
        'v12.stomp'
      end

      private

      def demo_path
        '/web-stomp/demo'
      end

      # STOMP frames are plain text, so CONNECT is hand-rollable.
      def connect_frame
        "CONNECT\naccept-version:1.0,1.1,1.2\nhost:#{endpoint.vhost}\n" \
          "login:#{endpoint.username}\npasscode:#{endpoint.password}\n\n\0"
      end

      def acknowledged?(frame)
        frame.to_s.start_with?('CONNECTED')
      end
    end
  end
end
