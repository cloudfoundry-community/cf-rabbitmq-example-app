require 'openssl'
require 'socket'
require 'timeout'

module RabbitMQ
  # Shared TLS policy for the adapters whose client gem does not verify a
  # broker certificate on its own.
  #
  # Bunny (amqps) and Net::HTTP (management_tls) both verify by default and
  # take Endpoint#verify_peer? directly. The other three gems do not:
  #
  #   ruby-mqtt 0.7.0      SSLContext.new with no verify_mode - VERIFY_NONE
  #   stomp 1.4.10         "ctx.verify_mode = VERIFY_NONE # Assume for now"
  #   websocket-client-simple 0.9.0
  #                        verify_mode only set if the caller passes one
  #
  # Left alone, all three complete a TLS handshake against any certificate
  # at all - measured against a broker holding a certificate from a CA in
  # no trust store: /mqtts/ping, /stomps/ping, /web-mqtt-tls/ping and
  # /web-stomp-tls/ping every one returned 200 OK. That is encryption
  # without authentication, reported as a healthy binding, which is the one
  # answer this app must never give.
  module TLS
    def self.verify_mode(endpoint)
      endpoint.verify_peer? ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    end

    # A store seeded from OpenSSL's default paths, which honour
    # SSL_CERT_FILE and SSL_CERT_DIR. That is the lever an operator has for
    # a private CA - every Blacksmith deployment signs its service
    # certificates with one - so no binding field or app-specific
    # environment variable is invented for it here.
    #
    # Fresh per call: an OpenSSL::X509::Store is mutable and gets handed
    # to a gem that may add to it (websocket-client-simple calls
    # set_default_paths on whatever store it is given), so sharing one
    # across connections would let one connection's trust decisions leak
    # into another's.
    def self.cert_store
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      store
    end

    # Bounded so an endpoint that accepts a TCP connection and then never
    # completes a handshake cannot hang the request.
    HANDSHAKE_TIMEOUT = 5

    # Returns nil when the broker's certificate verifies, or a one-line
    # reason when it does not.
    #
    # This exists for websocket-client-simple, which offers verify_mode but
    # no hook for hostname verification: Client#connect builds its own
    # SSLContext, and Ruby only runs post_connection_check when the context
    # asks for it. Chain verification alone would still accept a
    # certificate issued to a completely different name - measured: with
    # verify_mode set and a certificate for wrong.example.invalid, the
    # handshake to localhost still succeeded. So the identity check is done
    # here, on a connection this app controls end to end.
    #
    # The cost of doing it separately is that this is a second connection:
    # a broker that served one certificate here and another to the gem
    # would not be caught. That is a real gap, and the fix for it belongs
    # in the gem rather than here.
    def self.verify_endpoint(endpoint)
      Timeout.timeout(HANDSHAKE_TIMEOUT) do
        socket = OpenSSL::SSL::SSLSocket.new(
          TCPSocket.new(endpoint.host, endpoint.port), verified_context
        )
        socket.sync_close = true
        socket.hostname = endpoint.host
        begin
          socket.connect
          socket.post_connection_check(endpoint.host)
          nil
        ensure
          socket.close
        end
      end
    rescue OpenSSL::SSL::SSLError, OpenSSL::X509::CertificateError => e
      e.message
    rescue Timeout::Error
      "TLS handshake with #{endpoint.host}:#{endpoint.port} timed out"
    end

    def self.verified_context
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.cert_store = cert_store
      context
    end
  end
end
