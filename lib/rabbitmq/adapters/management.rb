require 'net/http'
require 'openssl'
require 'json'
require 'uri'
require_relative 'base'

module RabbitMQ
  module Adapters
    # The management HTTP API. Uses stdlib - no gem needed.
    #
    # This is also the queue-listing backend for every other adapter, which
    # is what lets the app hold no queue state of its own. declare, publish
    # and consume are intentionally not overridden: the inherited 501 from
    # Base is the correct behaviour for this read-only adapter.
    class Management < Base
      def overview
        get('/api/overview') || {}
      end

      def queues
        get("/api/queues/#{encoded_vhost}") || []
      end

      def queue_names
        queues.map { |q| q['name'] }
      end

      def queue(name)
        get("/api/queues/#{encoded_vhost}/#{URI.encode_www_form_component(name)}")
      end

      def queue_exists?(name)
        !queue(name).nil?
      end

      def ping
        [200, JSON.pretty_generate(overview)]
      end

      private

      def encoded_vhost
        URI.encode_www_form_component(endpoint.vhost)
      end

      # Returns nil on 404 so callers can distinguish missing from empty.
      def get(path)
        response = http.request(request_for(path))
        return nil if response.code == '404'
        raise "management API returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end

      def request_for(path)
        Net::HTTP::Get.new(path).tap do |req|
          req.basic_auth(endpoint.username, endpoint.password)
          req['Accept'] = 'application/json'
        end
      end

      def http
        Net::HTTP.new(endpoint.host, endpoint.port).tap do |client|
          client.use_ssl = endpoint.tls
          client.verify_mode = OpenSSL::SSL::VERIFY_NONE unless endpoint.verify_peer?
          client.open_timeout = 5
          client.read_timeout = 10
        end
      end
    end
  end
end
