module RabbitMQ
  module Adapters
    class QueueNotFound < StandardError; end
    class Unsupported < StandardError; end

    # Carries the upstream status and reason so routes can render an accurate
    # response instead of a blanket 500. Detail is truncated because an
    # upstream proxy may return an arbitrary HTML body.
    class ManagementError < StandardError
      DETAIL_LIMIT = 200

      attr_reader :status, :detail

      def initialize(status, detail)
        @status = status.to_i
        @detail = truncate(detail)
        super("management API returned #{@status}: #{@detail}")
      end

      private

      def truncate(text)
        flat = text.to_s.gsub(/\s+/, ' ').strip
        flat.length > DETAIL_LIMIT ? "#{flat[0, DETAIL_LIMIT]}..." : flat
      end
    end

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
