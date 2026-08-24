require 'stomp'
require 'timeout'
require_relative 'base'
require_relative '../tls'

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

      # The STOMP plugin has no "declare" verb - a queue comes into being
      # when something SUBSCRIBEs to it. That makes SUBSCRIBE the only way
      # to create one, but a plain subscription defaults to ack mode
      # "auto", and the consumer it registers is not torn down the instant
      # this method returns: close/unsubscribe are not synchronous, so the
      # broker can still consider it live for a few milliseconds afterwards.
      # A message published into that window was delivered to this
      # throwaway subscriber and auto-acked away - measured as the cause of
      # an intermittent 204 from #consume, roughly 30% of runs under load.
      #
      # ack "client" closes the hole: nothing is acked unless we mean it,
      # so anything delivered into a teardown window stays unacknowledged
      # and the broker requeues it when the connection goes away. Used by
      # declare (which never acks at all) and consume (which acks exactly
      # the message it returns).
      CLIENT_ACK_HEADERS = { 'ack' => 'client' }.freeze

      def declare(name)
        with_client do |client|
          client.subscribe(destination(name), CLIENT_ACK_HEADERS) { |_msg| nil }
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

      # Same hazard declare has, one step further along: unsubscribe and
      # close are fire-and-forget, so this subscription can still be live
      # on the broker for a moment after the timeout returns 204. Under
      # ack auto a message arriving in that window would be delivered to
      # a consumer nobody is reading any more and destroyed - the caller
      # already has its 204 and the message is gone for good. Acking only
      # the message actually handed back means anything else delivered
      # into the window is requeued instead.
      def consume(name)
        with_client do |client|
          message = nil
          client.subscribe(destination(name), CLIENT_ACK_HEADERS) { |msg| message = msg }
          begin
            Timeout.timeout(READ_TIMEOUT) { sleep 0.01 until message }
            client.acknowledge(message)
            [200, "#{message.body}\n"]
          rescue Timeout::Error
            [204, '']
          ensure
            client.unsubscribe(destination(name))
          end
        end
      end

      private

      # The stomp gem cannot verify a broker certificate at all here.
      # Connection#open_ssl_socket sets "ctx.verify_mode =
      # OpenSSL::SSL::VERIFY_NONE # Assume for now" and only raises it to
      # VERIFY_PEER when Stomp::SSLParams carries :ts_files - and that
      # branch guards each file with File::exists?, which no longer exists
      # on the Ruby this app runs (3.3.11), so supplying a trust store
      # raises NoMethodError before a socket is ever opened. 1.4.10 is the
      # newest release, so there is no version to bump to.
      #
      # Left at that, /stomps/ping answered 200 OK against a broker whose
      # certificate came from a CA in no trust store, and again against
      # one issued to a completely different hostname. Verifying the
      # endpoint ourselves first is what this app can honestly do: it
      # catches the wrong CA, the expired certificate and the wrong name.
      # It does NOT authenticate the connection the messages then travel
      # over - that needs the gem fixed. See RabbitMQ::TLS.verify_endpoint.
      def tls_failure_reason
        return nil unless endpoint.verify_peer?

        RabbitMQ::TLS.verify_endpoint(endpoint)
      end

      # Stomp::Client.new returns as soon as the socket is up: with
      # reliable false the gem does not raise when the broker answers
      # CONNECT with an ERROR frame, and every write below is
      # fire-and-forget. Without this guard a refused login still reached
      # #ping's unconditional [200, 'OK'] and #publish's [201, 'SUCCESS'],
      # so the app reported a healthy binding while the broker was turning
      # it away - the one answer a verification app must never give.
      #
      # The CONNECT outcome is readable on the client: a good login leaves
      # connection_frame.command == 'CONNECTED', a refused one leaves
      # 'ERROR' with the reason in headers['message'].
      def with_client
        reason = tls_failure_reason
        return [502, "ERR:TLS verification failed: #{reason}"] if reason

        client = ::Stomp::Client.new(connection_options)
        frame = client.connection_frame
        unless frame && frame.command == 'CONNECTED'
          reason = frame&.headers&.[]('message') || 'no CONNECTED frame'
          return [502, "ERR:STOMP CONNECT refused: #{reason}"]
        end

        yield client
      ensure
        client&.close
      end
    end
  end
end
