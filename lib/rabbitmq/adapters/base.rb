module RabbitMQ
  module Adapters
    class QueueNotFound < StandardError; end
    class Unsupported < StandardError; end

    # Adapters return [status, body] so routes stay free of protocol detail.
    class Base
      def initialize(endpoint)
        @endpoint = endpoint
      end

      attr_reader :endpoint

      def ping
        raise NotImplementedError
      end

      # Read-only-ness (management, management_tls) is a property of the
      # adapter, so the safe default lives here: an honest 501 rather than
      # an unhandled NotImplementedError bubbling into a 500.
      def declare(_name)
        unsupported("declare over #{@endpoint&.protocol}")
      end

      def publish(_name, _data)
        unsupported("publish over #{@endpoint&.protocol}")
      end

      def consume(_name)
        unsupported("consume over #{@endpoint&.protocol}")
      end

      private

      def unsupported(what)
        [501, "NOT-SUPPORTED: #{what}"]
      end
    end
  end
end
